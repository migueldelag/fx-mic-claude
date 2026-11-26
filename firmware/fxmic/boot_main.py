import ui
ui.callback(0)
# Boot stub, installed as /fat/main.py. Claude mode runs fxmic from /fat/claude; stock mode runs TE's own startup,
# which then finds no config.json at the disk root and loads the factory effects and sounds. The mode is kept in
# /fat/claude/mode. To switch: with the mic on and the handle released, hold the orange (FX) button for 3 s; the
# sample LEDs sweep up for Claude or down for stock, then turn the mic off and on to start in the new mode.
# A long press while running, rather than a button held at power-on, because the LEDs stay dark until startup (no
# feedback) and a boot-time check would delay every start. It is watched by a thin wrapper around whichever
# script's callback is running. Holding orange also steps the FX preset once; that resets at the restart.
# Kept short: the tick callback stays cleared until the real script installs its own.
import sys
try:
    mode = open('/fat/claude/mode').read().strip()
except Exception:
    mode = 'claude'
if mode == 'claude':
    try:
        sys.path.insert(0, '/fat/claude')
        import fxmic as started
    except Exception as e:
        print('fxmic failed, starting stock:', e)
        mode = 'stock'
        import teenage as started
else:
    import teenage as started

HOLD_TICKS = 180      # about 3 s at the 60 Hz tick
held_ticks = 0
sweep = []            # LED positions still to show in the confirmation sweep
frame = 0


def toggle_mode():
    global mode, sweep
    new = 'stock' if mode == 'claude' else 'claude'
    try:
        f = open('/fat/claude/mode', 'w')
        f.write(new)
        f.close()
    except Exception as e:
        print('mode not saved:', e)
        return
    mode = new
    sweep = (list(range(4)) if mode == 'claude' else list(range(3, -1, -1))) * 3


def watch(message):
    global held_ticks, sweep, frame
    started.python_callback(message)
    if (message >> 16) != 3:          # message type 3 is the 60 Hz tick
        return
    if ui.sw(2) == 0 and ui.handle() < 0.2:     # buttons top to bottom: orange sw(2) FX, white sw(1), grey sw(0) play
        held_ticks += 1
        if held_ticks == HOLD_TICKS:
            toggle_mode()
    else:
        held_ticks = 0
    if sweep:
        frame += 1
        if frame % 8 == 0:
            ui.leds(-1, sweep.pop(0))
            if not sweep:
                ui.leds(started.fx_pos, started.sam_pos)


try:
    ui.callback(watch)
except Exception as e:
    print('mode switch watcher not installed:', e)
