#!/usr/bin/env python3
"""Marker pack for USB adapters that cut everything above ~7 kHz (measured on an "AB13X USB Audio" dongle:
flat to 6 kHz, -20 dB at 7 kHz, nothing above). Same four slots and file names as marker-pack, so config.json
and the mic script stay as they are; only the pitches move into 3.4-5.7 kHz, where voiced speech is weak.

Tone pairs are 1.4 kHz apart so neither tone lands on the other's +/-600 Hz guard bins in FXMic's detector.
Louder than marker-pack (0.48 per tone) because this adapter path arrives about 47 dB down.

Install with `tools/install_disk.sh install marker-pack-lowband`, then point FXMic at the pitches in pitches.json
(the install script prints the `defaults write` commands). `tools/install_disk.sh install` goes back to the originals."""
import json, math, os, shutil, struct, wave

SR = 48000
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "packs", "marker-pack-lowband")
TONES = {
    "chirp.wav": (4000, 5400),    # tap (play button)
    "cancel.wav": (3400, 4800),   # shake while squeezed
    "press.wav": (4300, 5700),    # handle squeezed
    "release.wav": (3700, 5100),  # handle released
}

def burst(freqs, dur=0.12, amp=0.48, fade=0.005):
    n, nf = int(dur * SR), int(fade * SR)
    out = []
    for i in range(n):
        env = 0.5 - 0.5 * math.cos(math.pi * i / nf) if i < nf else (0.5 - 0.5 * math.cos(math.pi * (n - i) / nf) if i > n - nf else 1.0)
        out.append(sum(math.sin(2 * math.pi * f * i / SR) for f in freqs) * amp * env)
    return out

os.makedirs(OUT, exist_ok=True)
for name, freqs in TONES.items():
    with wave.open(os.path.join(OUT, name), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in burst(freqs)))
shutil.copy(os.path.join(HERE, "..", "packs", "marker-pack", "config.json"), os.path.join(OUT, "config.json"))
# FXMic settings keys for these pitches, applied with `defaults write com.miguel.fxmic <key> -array f1 f2`.
KEYS = {"chirp.wav": "chirpFreqs", "cancel.wav": "cancelFreqs", "press.wav": "pressFreqs", "release.wav": "releaseFreqs"}
with open(os.path.join(OUT, "pitches.json"), "w") as f:
    json.dump({KEYS[n]: list(v) for n, v in TONES.items()}, f, indent=1)
print("marker-pack-lowband:", sorted(os.listdir(OUT)))
