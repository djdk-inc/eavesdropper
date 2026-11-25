#!/usr/bin/env python3
"""Live end-to-end test of the installed app: Start Listening, play a conversation twice with a silent
gap between, Stop Listening, then check the finished meeting.

  ./live-test.py <conversation audio> [--rounds N] [--gap SECONDS] [--app PATH]

Passes when, for every round, the meeting finishes "done", both recordings run as long as the meeting
(a skipped-frames bug made call audio 23 s short of 263 s), the call side has speaker labels, and each
echoed "You" line lands within 2 s of the call line it repeats (the two sides line up).
Plays through the speakers; the app needs System Audio Recording and microphone access.
"""
import argparse
import json
import os
import statistics
import subprocess
import sys
import time
from datetime import datetime

STORE = os.path.expanduser("~/Library/Containers/com.djdk.eavesdropper/Data/Recordings/Eavesdropper")


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout


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


def one_round(app, audio, gap):
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
        m = meeting(folder)
        if m["status"] in ("done", "failed"):
            break
        time.sleep(2)
    else:
        sys.exit(f"{folder}: still {m['status']} after 3 minutes")

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
    speakers = sorted({t["speaker"] for t in lines} - {"You"})
    print(f"  speakers: {speakers}, lines: {len(lines)}")
    if not speakers:
        problems.append("no call-side speakers")
    # Without headphones the mic hears the speakers: each "You" line echoes a call line. Their offsets
    # measure how well the two files line up.
    offsets = []
    used = set()
    for you in (t for t in lines if t["speaker"] == "You"):
        match = [i for i, t in enumerate(lines) if t["speaker"] != "You" and i not in used
                 and t["text"].lower().rstrip(".") == you["text"].lower().rstrip(".")]
        if match:
            i = min(match, key=lambda i: abs(lines[i]["start"] - you["start"]))
            used.add(i)
            offsets.append(you["start"] - lines[i]["start"])
    if offsets:
        print(f"  echo offset: median {statistics.median(offsets):.2f} s, max {max(offsets, key=abs):.2f} s ({len(offsets)} pairs)")
        if max(abs(o) for o in offsets) > 2:
            problems.append(f"sides drift apart: an echo lands {max(offsets, key=abs):.1f} s off")
    return folder, problems


def main():
    p = argparse.ArgumentParser()
    p.add_argument("audio")
    p.add_argument("--rounds", type=int, default=1)
    p.add_argument("--gap", type=float, default=30)
    p.add_argument("--app", default="/Applications/Eavesdropper.app")
    a = p.parse_args()
    print(run(os.path.join(a.app, "Contents/MacOS/Eavesdropper"), "--version").strip())
    failed = 0
    for n in range(1, a.rounds + 1):
        print(f"round {n}")
        folder, problems = one_round(a.app, a.audio, a.gap)
        print(f"  {'PASS' if not problems else 'FAIL'} {folder}")
        for problem in problems:
            print(f"    - {problem}")
        failed += bool(problems)
    print(f"{a.rounds - failed}/{a.rounds} rounds passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
