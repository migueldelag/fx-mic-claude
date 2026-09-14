#!/usr/bin/env python3
"""Pack with a handle-following pilot tone (option 2).
slot 1: pilot.wav, a 19 kHz loop in startstop mode. The SAMPLE row sits at level 0.35 and the handle adds up to 0.65,
so the pilot is always present once started and rises about 9 dB when squeezed. The Mac reads handle position from that level.
slots 2-4: chirp.wav, a 15.5 + 16.5 kHz one-shot for taps.
Startup after each power-on: squeeze, press play once (pilot starts), press select once (chirp slot)."""
import json, math, os, struct, wave

SR = 48000
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "packs", "pilot-pack")
os.makedirs(OUT, exist_ok=True)

def write(path, samples):
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in samples))

# pilot: exactly whole cycles so the loop point is seamless. 19 kHz -> 1 s holds 19000 cycles.
PILOT_F, PILOT_AMP, PILOT_SEC = 19000.0, 0.25, 1.0
n = int(PILOT_SEC * SR)
write(os.path.join(OUT, "pilot.wav"), [math.sin(2 * math.pi * PILOT_F * i / SR) * PILOT_AMP for i in range(n)])

# chirp: two tones, 150 ms, short fades
F1, F2, AMP, DUR = 15500.0, 16500.0, 0.35, 0.15
n, nf = int(DUR * SR), int(0.005 * SR)
chirp = []
for i in range(n):
    env = 0.5 - 0.5 * math.cos(math.pi * i / nf) if i < nf else (0.5 - 0.5 * math.cos(math.pi * (n - i) / nf) if i > n - nf else 1.0)
    chirp.append((math.sin(2 * math.pi * F1 * i / SR) + math.sin(2 * math.pi * F2 * i / SR)) * AMP * env)
write(os.path.join(OUT, "chirp.wav"), chirp)

config = {
    "name": "CLAUDE PILOT",
    "samples": [
        {"pos": 0, "file": "pilot.wav", "playmode": "startstop"},
        {"pos": 1, "file": "chirp.wav", "playmode": "oneshot"},
        {"pos": 2, "file": "chirp.wav", "playmode": "oneshot"},
        {"pos": 3, "file": "chirp.wav", "playmode": "oneshot"},
    ],
    # Every preset is dry. Row 0 is the SAMPLE row: base level 0.35, the handle adds up to 0.65 (released 0.35, squeezed 1.0).
    "presets": [
        {"pos": p, "list": [{"effect": "SAMPLE", "level": 0.35}], "handle": {"row": 0, "param": "level", "depth": 0.65}, "trigger": {"row": 0}}
        for p in range(4)
    ],
}
with open(os.path.join(OUT, "config.json"), "w") as f:
    json.dump(config, f, indent=1)
with open(os.path.join(OUT, "README.md"), "w") as f:
    f.write(__doc__ + "\nThe chirp on slots 2-4 is scaled by the same handle modulation: 35 percent when released, full when squeezed. Both are well above the detector floor.\n")
print("pilot-pack written:", sorted(os.listdir(OUT)))
