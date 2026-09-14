exec("""
import time
t0 = time.ticks_ms()
last = None
lo = 9e9; hi = -9e9; rlo = 9e9; rhi = -9e9
while time.ticks_diff(time.ticks_ms(), t0) < 60000:
    h = ui.handle(); r = ui.handle_raw()
    lo = min(lo, h); hi = max(hi, h); rlo = min(rlo, r); rhi = max(rhi, r)
    cur = (round(h, 2), round(r, 1) if isinstance(r, float) else r)
    if cur != last:
        print(time.ticks_diff(time.ticks_ms(), t0), cur)
        last = cur
    time.sleep_ms(50)
print('handle range', lo, hi, 'raw range', rlo, rhi)
print('PROBE END')
""")
