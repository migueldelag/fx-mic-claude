exec("""
import time
print('shaker attr:', repr(ui.shaker))
try:
    print('shaker():', ui.shaker())
except Exception as e:
    print('shaker() error:', e)
_types = {}
_orig = python_callback if 'python_callback' in dir() else None
import sys
_m = sys.modules.get('fxmic')
_orig = _m.python_callback if _m else _orig
def _probe_cb(msg):
    t = msg >> 16
    if t not in (3,) and (t & 0xF0) != 0x10:
        _types[t] = _types.get(t, 0) + 1
    if _orig: _orig(msg)
ui.callback(_probe_cb)
t0 = time.ticks_ms()
last = None
while time.ticks_diff(time.ticks_ms(), t0) < 30000:
    a = ui.acc()
    h = ui.handle()
    try:
        s = ui.shaker()
    except Exception:
        s = None
    print(time.ticks_diff(time.ticks_ms(), t0), a[0], a[1], a[2], round(h, 2), s)
    time.sleep_ms(20)
ui.callback(_orig)
print('other message types seen:', _types)
print('PROBE END')
""")
