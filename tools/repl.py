#!/usr/bin/env python3
"""Send lines to the EP-2350 MicroPython REPL and print what comes back. Read-only unless you type otherwise.
usage: tools/repl.py "expr" ["expr" ...]   (each is sent as one line; response window 1.5 s)"""
import os, select, sys, time, glob, subprocess

_ports = sorted(glob.glob("/dev/cu.usbmodem*"))
PORT = next((p for p in _ports if "EP" in p), _ports[0] if _ports else "/dev/cu.usbmodem-missing")
subprocess.run(["stty", "-f", PORT, "115200", "raw", "-echo", "clocal"], check=False)
fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)

def read_for(seconds):
    out = b""; end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try: out += os.read(fd, 4096)
            except BlockingIOError: pass
    return out.decode("utf-8", "replace")

banner = read_for(0.8)
if banner.strip(): print("<<", banner.strip().replace("\r", ""))
for cmd in sys.argv[1:]:
    forbidden = any(ord(c) < 32 and c not in "\r\n\t" for c in cmd)
    if forbidden: print("refusing control characters"); continue
    os.write(fd, (cmd + "\r\n").encode())
    resp = read_for(float(os.environ.get("REPL_WAIT", "1.5")))
    print(f">> {cmd}")
    print(resp.replace("\r", "").rstrip())
os.close(fd)
