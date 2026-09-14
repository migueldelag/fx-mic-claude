exec("""
import time
_adc = {}
_cnt = {}
_types = {}
_orig_cb = python_callback
def _probe_cb(m):
    t = m >> 16; v = m & 0xFFFF
    _types[t] = _types.get(t, 0) + 1
    if t & 0xF0 == 0x10:
        a = t & 0x0F
        lo, hi = _adc.get(a, (v, v))
        _adc[a] = (min(lo, v), max(hi, v))
        _cnt[a] = _cnt.get(a, 0) + 1
    _orig_cb(m)
ui.callback(_probe_cb)
t0 = time.ticks_ms()
last = None
while time.ticks_diff(time.ticks_ms(), t0) < 45000:
    h = ui.handle()
    cur = (round(h, 2), _adc.get(0), _adc.get(1))
    if cur != last:
        print(time.ticks_diff(time.ticks_ms(), t0), 'handle', cur)
        last = cur
    time.sleep_ms(100)
ui.callback(python_callback)
print('ADC ranges', _adc)
print('ADC counts', _cnt)
print('message types', _types)
print('PROBE END')
""")
