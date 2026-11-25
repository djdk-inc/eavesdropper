#!/usr/bin/env python3
"""Live end-to-end test of the installed app. Each round generates a fresh meeting (a random dialogue
from test/dialogues.json, spoken by random distinct Kokoro neural voices), Starts Listening, plays it twice with
a silent gap between, Stops Listening, then checks the finished meeting against what was said.

  ./live-test.py [--rounds N] [--gap SECONDS] [--audio FILE] [--app PATH] [--seed N]

A round passes when the meeting finishes "done", both recordings run as long as the meeting (a
skipped-frames bug once made call audio 23 s short of 263 s), the call side has speaker labels, it
transcribes at least 80% of the spoken words, and each echoed "You" line lands within 2 s of the call
line it repeats (the two sides line up). Speaker counts are reported, not enforced: similar voices merge.
--audio plays a fixed file instead and skips the word and speaker scoring.
Plays through the speakers; the app needs System Audio Recording and microphone access.
"""
import argparse
import collections
import json
import os
import random
import re
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
STORE = os.path.expanduser("~/Library/Containers/com.djdk.eavesdropper/Data/Recordings/Eavesdropper")
KOKORO_PYTHON = os.path.join(HERE, ".venv/bin/python")
# Kokoro's English voices (US a*, UK b*), minus the novelty ones (santa) and the whispery nicole.
KOKORO_VOICES = ["af_heart", "af_bella", "af_sarah", "af_nova", "af_jessica", "af_river", "af_aoede",
                 "am_michael", "am_adam", "am_eric", "am_liam", "am_onyx", "am_puck",
                 "bf_emma", "bf_isabella", "bf_alice", "bf_lily", "bm_george", "bm_lewis", "bm_daniel", "bm_fable"]


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout


def words(text):
    return re.findall(r"[a-z0-9']+", text.lower())


def generate(rng, folder):
    """A meeting as one WAV, spoken by Kokoro's neural voices: returns (path, dialogue lines, voices)."""
    dialogue = rng.choice(json.load(open(os.path.join(HERE, "test/dialogues.json"))))
    roles = sorted({role for role, _ in dialogue})
    voices = dict(zip(roles, rng.sample(KOKORO_VOICES, len(roles))))
    speeds = {r: rng.uniform(0.95, 1.1) for r in roles}  # each person keeps their own pace
    turns = [{"voice": voices[r], "text": t, "speed": speeds[r], "pause": rng.uniform(0.2, 1.0)} for r, t in dialogue]
    path = os.path.join(folder, "meeting.wav")
    subprocess.run([KOKORO_PYTHON, os.path.join(HERE, "test/kokoro_meeting.py")], check=True,
                   input=json.dumps({"out": path, "turns": turns}), text=True, capture_output=True)
    print(f"  dialogue: {dialogue[0][1][:50]}… voices: {', '.join(voices[r] for r in roles)}")
    return path, [text for _, text in dialogue], len(roles)


def duration(path):
    for line in run("afinfo", path).splitlines():
        if line.startswith("estimated duration:"):
            return float(line.split()[2])
    raise RuntimeError(f"no duration for {path}")


def meeting(folder):
    with open(os.path.join(STORE, folder, "meeting.json")) as f:
        return json.load(f)


def parse(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def record(app, audio, gap):
    """Start Listening, play twice with a silent gap, Stop; returns the finished meeting's folder."""
    binary = os.path.join(app, "Contents/MacOS/Eavesdropper")
    if "call   none" not in run(binary, "--probe"):
        sys.exit("a call is active; not recording over it")
    before = set(os.listdir(STORE))
    run(binary, "--control", "start")
    time.sleep(2)
    new = [d for d in set(os.listdir(STORE)) - before if d.endswith("Manual recording")]
    if len(new) != 1:
        sys.exit(f"Start Listening made no recording (new folders: {new})")
    folder = new[0]
    time.sleep(3)
    run("afplay", audio)
    time.sleep(gap)  # silence: where a tap skips frames
    run("afplay", audio)
    time.sleep(2)
    run(binary, "--control", "stop")
    for _ in range(90):
        if meeting(folder)["status"] in ("done", "failed"):
            return folder
        time.sleep(2)
    sys.exit(f"{folder}: still not transcribed after 3 minutes")


def check(folder, spoken, voices):
    m = meeting(folder)
    problems = []
    if m["status"] != "done":
        problems.append(f"status {m['status']}: {m.get('error')}")
    length = (parse(m["endedAt"]) - parse(m["startedAt"])).total_seconds()
    for side in ("mic", "call"):
        seconds = duration(os.path.join(STORE, folder, f"{side}.m4a"))
        print(f"  {side}: {seconds:.1f} s of {length:.1f} s")
        if abs(seconds - length) > 2:
            problems.append(f"{side} audio is {seconds:.1f} s, meeting ran {length:.1f} s")
    lines = m["transcript"]
    call = [t for t in lines if t["speaker"] != "You"]
    speakers = sorted({t["speaker"] for t in call})
    print(f"  speakers: {len(speakers)} labeled for {voices or '?'} voices, {len(lines)} lines")
    if not speakers or speakers == ["Others"]:
        problems.append("no call-side speaker labels")
    if spoken:
        # Played twice, so every spoken word should be heard twice.
        said = collections.Counter(w for text in spoken for w in words(text))
        said = collections.Counter({w: 2 * n for w, n in said.items()})
        heard = collections.Counter(w for t in call for w in words(t["text"]))
        recall = sum((said & heard).values()) / sum(said.values())
        print(f"  words heard: {recall:.0%}")
        if recall < 0.8:
            problems.append(f"call side heard only {recall:.0%} of the spoken words")
    # Without headphones the mic hears the speakers: each "You" line echoes a call line (the nearest one
    # with the same words within 10 s: the meeting is played twice, and a line one side splits differently
    # would otherwise pair with its copy a playback away). Their offsets measure how well the sides line up.
    offsets = []
    for you in (t for t in lines if t["speaker"] == "You"):
        near = [t["start"] - you["start"] for t in call if words(t["text"]) == words(you["text"])
                and abs(t["start"] - you["start"]) < 10]
        if near:
            offsets.append(-min(near, key=abs))
    if offsets:
        worst = max(offsets, key=abs)
        print(f"  echo offset: median {statistics.median(offsets):.2f} s, worst {worst:.2f} s ({len(offsets)} pairs)")
        if abs(worst) > 2:
            problems.append(f"sides drift apart: an echo lands {worst:.1f} s off")
    return problems


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--rounds", type=int, default=1)
    p.add_argument("--gap", type=float, default=30)
    p.add_argument("--audio", help="play this file instead of a generated meeting")
    p.add_argument("--app", default="/Applications/Eavesdropper.app")
    p.add_argument("--seed", type=int, help="repeat a run's dialogue and voices")
    a = p.parse_args()
    sys.stdout.reconfigure(line_buffering=True)  # progress shows while rounds run
    seed = a.seed if a.seed is not None else random.randrange(10**6)
    rng = random.Random(seed)
    if not a.audio and not (os.path.exists(KOKORO_PYTHON) and os.path.isdir(os.path.join(HERE, ".models/kokoro"))):
        sys.exit("test voices aren't set up: see 'Test speech' in AGENTS.md (or pass --audio FILE)")
    print(run(os.path.join(a.app, "Contents/MacOS/Eavesdropper"), "--version").strip(), f"| seed {seed}")
    failed = 0
    for n in range(1, a.rounds + 1):
        print(f"round {n}")
        with tempfile.TemporaryDirectory() as tmp:
            audio, spoken, voices = (a.audio, None, None) if a.audio else generate(rng, tmp)
            folder = record(a.app, audio, a.gap)
        problems = check(folder, spoken, voices)
        print(f"  {'PASS' if not problems else 'FAIL'} {folder}")
        for problem in problems:
            print(f"    - {problem}")
        failed += bool(problems)
    print(f"{a.rounds - failed}/{a.rounds} rounds passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
