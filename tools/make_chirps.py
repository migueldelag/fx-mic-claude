#!/usr/bin/env python3
"""Write the test chirp pack: three near-inaudible two-tone bursts and one audible reference beep."""
import math, os, struct, sys, wave

SR = 48000
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "packs", "test-chirps")
SLOTS = {
    1: ([12000, 13000], 0.35),
    2: ([14000, 15000], 0.35),
    3: ([15500, 16500], 0.35),
    4: ([17000, 18500], 0.35),
}

def burst(freqs, amp, dur=0.150, fade=0.008, sr=SR):
    n, nf = int(dur * sr), int(fade * sr)
    out = []
    for i in range(n):
        env = 1.0
        if i < nf:
            env = 0.5 - 0.5 * math.cos(math.pi * i / nf)
        elif i > n - nf:
            env = 0.5 - 0.5 * math.cos(math.pi * (n - i) / nf)
        out.append(sum(math.sin(2 * math.pi * f * i / sr) for f in freqs) * amp * env)
    return out

def write(path, samples, sr=SR):
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in samples))

os.makedirs(OUT, exist_ok=True)
for slot, (freqs, amp) in SLOTS.items():
    path = os.path.join(OUT, f"{slot}.wav")
    write(path, burst(freqs, amp))
    print(f"{path}: {'+'.join(str(f) for f in freqs)} Hz, {os.path.getsize(path)} bytes")
