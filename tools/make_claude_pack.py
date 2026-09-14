#!/usr/bin/env python3
"""Final pack for talking to Claude: one control tone on all four slots (hold playmode), dry presets, no ducking.
usage: tools/make_claude_pack.py [f1 f2]   default 17000 18500"""
import json, math, os, struct, sys, wave

SR = 48000
F1, F2 = (float(sys.argv[1]), float(sys.argv[2])) if len(sys.argv) >= 3 else (17000.0, 18500.0)
DUR = 0.15       # one-shot: every press gives the same 150 ms chirp. Hold mode was tried and never produced short tones.
AMP = 0.35       # per tone; measured about -22 dBFS at the Mac with the knob where it was on 2026-09-12
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "packs", "claude-pack")
os.makedirs(OUT, exist_ok=True)

n, nf = int(DUR * SR), int(0.005 * SR)
samples = []
for i in range(n):
    env = 0.5 - 0.5 * math.cos(math.pi * i / nf) if i < nf else 1.0
    samples.append((math.sin(2 * math.pi * F1 * i / SR) + math.sin(2 * math.pi * F2 * i / SR)) * AMP * env)
with wave.open(os.path.join(OUT, "chirp.wav"), "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in samples))

config = {
    "name": "CLAUDE",
    "samples": [{"pos": p, "file": "chirp.wav", "playmode": "oneshot"} for p in range(4)],
    "presets": [{"pos": p, "list": [{"effect": "SAMPLE", "level": 1.0}], "trigger": {"row": 0}} for p in range(4)],
}
with open(os.path.join(OUT, "config.json"), "w") as f:
    json.dump(config, f, indent=1)
with open(os.path.join(OUT, "README.md"), "w") as f:
    f.write(f"""# claude-pack

Sample pack for using the EP-2350 as a push-to-talk mic for Claude.

- chirp.wav: {F1/1000:g} + {F2/1000:g} kHz dual tone, {DUR:g} s, one-shot on all four slots.
  Every press gives the same short chirp. Tap, double tap, and triple tap are told apart by timing. The sample-select button no longer matters.
- config.json: four identical dry presets, so the FX button cannot color the voice. Samples are not ducked.
- Load: copy chirp.wav and config.json to FX MIC DISK, eject, power off with the small button, squeeze to start.
- Restore the party sounds: delete config.json and any 1.wav to 4.wav from the disk, restart. Factory copy in factory-pack/.
- Recovery if the mic will not start: hold sample-select + play while starting, then fix or delete config.json.
""")
print(f"chirp {F1:.0f}+{F2:.0f} Hz, {DUR} s, {os.path.getsize(os.path.join(OUT, 'chirp.wav'))} bytes; config.json written to {OUT}")
