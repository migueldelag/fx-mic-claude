#!/usr/bin/env python3
"""Synthetic sequence for the offline detector test: A, B double, C, D triple, at -20 dB, with silences."""
import os, struct, sys, wave
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_chirps import burst, write, SLOTS, SR

def silence(sec): return [0.0] * int(sec * SR)
def chirp(slot, gain=0.1):
    freqs, amp = SLOTS[slot]
    return [s * gain for s in burst(freqs, amp)]

seq = silence(0.5) + chirp(1) + silence(1.0) + chirp(2) + silence(0.30) + chirp(2) + silence(1.0) \
    + chirp(3) + silence(1.0) + chirp(4) + silence(0.30) + chirp(4) + silence(0.30) + chirp(4) + silence(1.0)
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
os.makedirs(out, exist_ok=True)
path = os.path.join(out, "sequence_test.wav")
write(path, seq)
print(path, f"{len(seq)/SR:.2f} s")
print("expected: TAP single A, TAP DOUBLE B, TAP single C, TAP x3 D")
