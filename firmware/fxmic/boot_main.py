import ui
ui.callback(0)
# Boot stub, installed as /fat/main.py. Claude mode runs fxmic from /fat/claude; stock mode runs TE's own startup,
# which then finds no config.json at the disk root and loads the factory effects and sounds. The mode is kept in
# /fat/claude/mode. To choose: with the mic on and the handle released, hold orange (FX) for 3 s for Claude mode or
# white (sample) for 3 s for stock; the sample LEDs sweep up for Claude or down for stock (also when it already was),
# then turn the mic off and on to start in that mode.
# A long press while running, rather than a button held at power-on, because the LEDs stay dark until startup (no
# feedback) and a boot-time check would delay every start. It is watched by a thin wrapper around whichever
# script's callback is running. Holding a select button also steps its preset or sample once, like any press; that
# resets at the restart. Grey (play) is left alone: it plays a sample, and in Claude mode it brings Claude forward.
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
held_button = -1
blocked = False       # the current hold overlapped a squeeze (queue/draft gesture): never a mode switch
sweep = []            # LED positions still to show in the confirmation sweep
frame = 0


def choose_mode(new):
    global mode, sweep
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
    global held_ticks, held_button, blocked, sweep, frame
    started.python_callback(message)
    if (message >> 16) != 3:          # message type 3 is the 60 Hz tick
        return
    # Buttons top to bottom: orange sw(2) FX, white sw(1) sample, grey sw(0) play. Exactly one of orange and white,
    # pressed and held with the handle released the whole time (holding one while letting go of the handle is the
    # queue/draft gesture, so a hold that overlapped a squeeze never switches modes).
    orange, white = ui.sw(2) == 0, ui.sw(1) == 0
    button = 2 if orange and not white else 1 if white and not orange else -1
    squeezed = ui.handle() >= 0.2
    if button != held_button:         # a new press, or a release: start over
        held_ticks = 0
        blocked = squeezed
    if squeezed:
        blocked = True
    if button >= 0 and not blocked:
        held_ticks += 1
        if held_ticks == HOLD_TICKS:
            choose_mode('claude' if button == 2 else 'stock')
    held_button = button
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
