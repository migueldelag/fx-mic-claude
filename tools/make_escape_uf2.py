#!/usr/bin/env python3
"""Builds firmware/te/escape_blank_disk.uf2: 8 KB of blank flash over the start of the EP-2350's 1 MB disk
(0x10100000 on the 2 MB chip). Dragged onto the "FX MIC BOOT" drive it makes the disk unreadable, so the firmware
reformats it at the next start and any bad main.py is gone. TE's own firmware UF2 never touches this region."""
import os, struct
FAMILY = 0xE48BFF59            # RP2350 ARM-S, the family TE's firmware uses
BASE, SIZE = 0x10100000, 8192
blocks = SIZE // 256
out = bytearray()
for i in range(blocks):
    out += struct.pack("<IIIIIIII", 0x0A324655, 0x9E5D5157, 0x2000, BASE + i * 256, 256, i, blocks, FAMILY)
    out += b"\xff" * 256 + b"\x00" * (476 - 256) + struct.pack("<I", 0x0AB16F30)
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "firmware", "te", "escape_blank_disk.uf2")
os.makedirs(os.path.dirname(path), exist_ok=True)
open(path, "wb").write(out)
print(f"{os.path.relpath(path)}: {len(out)} bytes, {blocks} blocks at 0x{BASE:08x}")
