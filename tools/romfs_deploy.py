#!/usr/bin/env python3
"""Build a ROMFS image from a directory (mpremote's own builder) and write it to the EP-2350 over the raw REPL
without toggling modem lines. usage: tools/romfs_deploy.py <dir> [--dry-run]"""
import base64, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mp_exec import open_port, raw_exec
from mpremote.romfs import make_romfs

src = sys.argv[1]
dry = "--dry-run" in sys.argv
image = make_romfs(src, mpy_cross=None)
print(f"romfs image: {len(image)} bytes from {sorted(os.listdir(src))}")
if dry: sys.exit(0)

fd = open_port()
def run(code, timeout=20):
    out, err = raw_exec(fd, code, timeout)
    if out is None or (err and err.strip()):
        sys.exit(f"device error for {code[:60]!r}: {err}")
    return out.strip()

n = int(run("import vfs; print(vfs.rom_ioctl(1))"))
print("rom partitions:", n)
rom_id = 0
info = run(f"dev=vfs.rom_ioctl(2,{rom_id}); print(dev.ioctl(4,0), dev.ioctl(5,0))").split()
blocks, block_size = int(info[0]), int(info[1])
print(f"partition: {blocks} blocks x {block_size} = {blocks * block_size} bytes")
if len(image) > blocks * block_size: sys.exit("image too big for the partition")
run("try:\n vfs.umount('/rom')\nexcept Exception as e:\n print('umount', e)")
run("from binascii import a2b_base64, b2a_base64")
nblocks = (len(image) + block_size - 1) // block_size
for b in range(nblocks):
    run(f"dev.ioctl(6,{b})")                       # erase
print(f"erased {nblocks} blocks")
PIECE = 512                                         # the device has little free RAM: write in small pieces at block offsets
for b in range(nblocks):
    for off in range(0, block_size, PIECE):
        pos = b * block_size + off
        part = image[pos:pos + PIECE]
        if not part: break
        part += bytes(PIECE - len(part))
        run(f"dev.writeblocks({b},a2b_base64('{base64.b64encode(part).decode()}'),{off})")
    print(f"  wrote block {b + 1}/{nblocks}")
# read back piece by piece and compare on the host
total = nblocks * block_size
padded = image + bytes(total - len(image))
ok = True
for b in range(nblocks):
    for off in range(0, block_size, PIECE):
        got = run(f"ba=bytearray({PIECE}); dev.readblocks({b},ba,{off}); print(b2a_base64(ba).decode().strip())")
        pos = b * block_size + off
        n = max(0, min(PIECE, len(image) - pos))          # bytes past the image end are don't-care
        if n and base64.b64decode(got)[:n] != image[pos:pos + n]:
            ok = False; print(f"  MISMATCH at block {b} offset {off}")
print("readback:", "MATCH" if ok else "MISMATCH")
if not ok: sys.exit("readback mismatch, not remounting")
run("vfs.mount(vfs.VfsRom(dev), '/rom')")
print("verify:", run("import os; print(os.listdir('/rom'), os.stat('/rom/main.py')[6])"))
os.close(fd)
print("done. Power-cycle the mic to run the new script.")
