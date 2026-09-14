#!/usr/bin/env python3
"""Read-only probe of the EP-2350 console: dump /rom docs and main.py, sample getters, stream changes for 60 s."""
import os, select, subprocess, sys, time, glob
PORT = (glob.glob("/dev/cu.usbmodemEPXYW*") or ["/dev/cu.usbmodemEPXYW3YH1"])[0]
subprocess.run(["stty", "-f", PORT, "115200", "raw", "-echo", "clocal"], check=False)
fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
def read_for(seconds, live=False):
    out = b""; end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                chunk = os.read(fd, 4096); out += chunk
                if live: sys.stdout.write(chunk.decode("utf-8", "replace").replace("\r", "")); sys.stdout.flush()
            except BlockingIOError: pass
    return out.decode("utf-8", "replace").replace("\r", "")
def send(cmd, wait=2.0, live=False):
    os.write(fd, (cmd + "\r\n").encode())
    return read_for(wait, live)
read_for(0.5)
print("=" * 30, "/rom/README.md"); print(send("print(open('/rom/README.md').read())", 4))
print("=" * 30, "/rom/main.py"); print(send("print(open('/rom/main.py').read())", 4))
print("=" * 30, "getters")
for g in ["ui.handle()", "ui.handle_raw()", "ui.sw()", "ui.acc()", "ui.get_vbus()", "ui.get_vbat()", "ui.get_temp()", "fx.list_loaded()", "fx.list_preset()"]:
    print(send(g, 1.2).strip())
print("=" * 30, "streaming handle/sw changes for 60 s", time.strftime("%H:%M:%S"))
loop = ("exec(\"import time\\nlast=None\\nt0=time.ticks_ms()\\nwhile time.ticks_diff(time.ticks_ms(),t0)<60000:\\n"
        " h=ui.handle()\\n h=round(h,2) if isinstance(h,float) else h\\n v=(h,ui.sw())\\n"
        " if v!=last:\\n  print(time.ticks_diff(time.ticks_ms(),t0),v)\\n  last=v\\n time.sleep_ms(30)\\nprint('END')\")")
send(loop, 63, live=True)
print("=" * 30, "done", time.strftime("%H:%M:%S"))
os.close(fd)
