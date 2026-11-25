"""Renders a meeting with Kokoro (a local neural TTS, Apache-2.0) for live-test.py.
Reads {"out": path, "turns": [{"voice", "text", "speed", "pause"}]} on stdin; writes one mono WAV.
Model files live in .models/kokoro (see AGENTS.md); runs in the test venv, never in the app.
"""
import json
import os
import sys

import numpy as np
import soundfile as sf
from kokoro_onnx import Kokoro

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".models", "kokoro")
spec = json.load(sys.stdin)
kokoro = Kokoro(os.path.join(root, "kokoro-v1.0.int8.onnx"), os.path.join(root, "voices-v1.0.bin"))
if spec.get("list"):
    print(json.dumps(sorted(kokoro.get_voices())))
    sys.exit(0)
parts, rate = [], 24000
for turn in spec["turns"]:
    lang = "en-gb" if turn["voice"][0] == "b" else "en-us"
    samples, rate = kokoro.create(turn["text"], voice=turn["voice"], speed=turn["speed"], lang=lang)
    parts += [samples, np.zeros(int(rate * turn["pause"]), dtype=samples.dtype)]
sf.write(spec["out"], np.concatenate(parts), rate)
