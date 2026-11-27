#!/usr/bin/env python3
"""Build the FXMic startup script for the EP-2350 by patching Teenage Engineering's own startup script.

TE's script is copyrighted and is not part of this repository. It is read from YOUR mic (its /rom/main.py) over
the serial console, or from a local copy you extracted yourself, and our additions are inserted:
handle press/release markers, shake-to-cancel, and a play button pinned to slot 1.

usage:
  tools/build_fxmic_script.py --from-device          # mic on USB-C, reads /rom/main.py over the console
  tools/build_fxmic_script.py --from-file path/to/te_main.py
Writes firmware/fxmic/main.py (git-ignored). Then: tools/install_disk.sh install
"""
import os, sys

ADDITIONS = "# ---- fxmic additions: play a marker sample when the handle is squeezed and another when it is released ----\nHANDLE_ON = 0.5         # ui.handle() units, set from the probe so a light touch does not count\nHANDLE_OFF = 0.3\nPRESS_SLOT = 2          # press.wav\nRELEASE_SLOT = 3        # release.wav\nCANCEL_SLOT = 1         # cancel.wav, played once per squeeze when the mic is shaken\nTAP_SLOT = 0            # chirp.wav, the play button's tone\nMODIFIER_AFTER = 15     # ticks into a squeeze (~250 ms) before a modifier may sound, so it never overlaps the press tone\nMODIFIER_STEADY = 3     # ticks a button must be held alone (~50 ms), so pressing both or rolling between them sends nothing\nMODIFIER_GAP = 9        # ticks between modifier tones (~150 ms; each tone is 120 ms), so a new one never cuts the last\nONE_G = 17400           # accelerometer counts at rest (probe: 17000-17900). Rotating the mic keeps the magnitude here.\nSHAKE_DEV = 7000        # excursion from one g that counts (about 0.4 g)\nSHAKE_EXCURSIONS = 3    # alternating above/below excursions needed: a shake oscillates, a gesture does not\nSHAKE_WINDOW = 30       # ticks (about 550 ms)\nhandle_down = False\nhandle_count = 0\nmarker_release = -1     # slot whose trigger is released on the next tick\nexcursions = []         # (tick, sign) of alternating excursions\ntick_no = 0\ncanceled_this_squeeze = False\nsqueeze_ticks = 0\nmodifier_for = -1       # button whose tone was last sent in this squeeze (2 orange, 1 white)\nmodifier_seen = -1      # button held alone right now, and for how many ticks\nmodifier_steady = 0\nmodifier_want = -1      # the last button held alone long enough: sent as soon as the gap allows\nmodifier_tick = -100    # tick_no of the last modifier tone\nUSB_HELLO = 120         # ticks (~2 s) between \"fxmic hi\" lines: FXMic trusts the USB reports only while they arrive\nplay_down = False\n\ndef report(word):\n    # One line per event on the USB serial console, for FXMic: with the mic on a USB-C data cable it takes squeezes\n    # from here and keeps the Mac's input closed between them. With no host listening the line goes nowhere. The\n    # tones still play, so a mic on batteries works as before.\n    try:\n        print('fxmic', word)\n    except Exception:\n        pass\n\ndef usb_update():\n    # The heartbeat, and the play button: a tap with the handle released (bring Claude forward, two = sleep), a\n    # draft during a squeeze (it plays the tap tone then too).\n    global play_down\n    if tick_no % USB_HELLO == 0:\n        report('hi')\n    down = ui.sw(0) == 0\n    if down and not play_down:\n        report('draft' if handle_down else 'tap')\n    play_down = down\n\ndef modifier_update():\n    # Pressing orange (FX) during a squeeze plays the press tone again = queue; white (sample) plays the tap tone\n    # = draft. Pressing the other one later in the same squeeze switches: its tone is sent too, and FXMic keeps\n    # the latest. FXMic reads them mid-squeeze, so its Listening bar shows the mode before the release.\n    global squeeze_ticks, modifier_for, modifier_seen, modifier_steady, modifier_want, modifier_tick, marker_release\n    if not handle_down:\n        squeeze_ticks = 0\n        modifier_for = -1\n        modifier_seen = -1\n        modifier_want = -1\n        return\n    squeeze_ticks += 1\n    orange, white = ui.sw(2) == 0, ui.sw(1) == 0\n    button = 2 if orange and not white else 1 if white and not orange else -1\n    if button != modifier_seen:\n        modifier_seen = button\n        modifier_steady = 0\n    modifier_steady += 1\n    if button >= 0 and modifier_steady >= MODIFIER_STEADY:\n        modifier_want = button\n    if squeeze_ticks < MODIFIER_AFTER or modifier_want < 0 or modifier_want == modifier_for:\n        return\n    if tick_no - modifier_tick < MODIFIER_GAP:\n        return\n    modifier_for = modifier_want\n    modifier_tick = tick_no\n    slot = PRESS_SLOT if modifier_for == 2 else TAP_SLOT\n    spl.trigger(-1, slot, True)\n    marker_release = slot\n    report('queue' if modifier_for == 2 else 'draft')\n\ndef shake_update():\n    global excursions, tick_no, canceled_this_squeeze, marker_release\n    tick_no += 1\n    if not handle_down:\n        excursions = []\n        return\n    a = ui.acc()\n    d = int((a[0]*a[0] + a[1]*a[1] + a[2]*a[2]) ** 0.5) - ONE_G\n    if d > SHAKE_DEV or d < -SHAKE_DEV:\n        sgn = 1 if d > 0 else -1\n        if not excursions or excursions[-1][1] != sgn:\n            excursions.append((tick_no, sgn))\n    excursions = [e for e in excursions if tick_no - e[0] <= SHAKE_WINDOW]\n    if len(excursions) >= SHAKE_EXCURSIONS and not canceled_this_squeeze:\n        canceled_this_squeeze = True\n        excursions = []\n        spl.trigger(-1, CANCEL_SLOT, True)\n        marker_release = CANCEL_SLOT\n        report('cancel')\n\ndef handle_update(v):\n    global handle_down, handle_count, marker_release, canceled_this_squeeze\n    if (not handle_down) and v > HANDLE_ON:\n        handle_count += 1\n        if handle_count >= 2:\n            handle_down = True\n            handle_count = 0\n            canceled_this_squeeze = False\n            spl.trigger(-1, PRESS_SLOT, True)\n            marker_release = PRESS_SLOT\n            report('press')\n    elif handle_down and v < HANDLE_OFF:\n        handle_count += 1\n        if handle_count >= 2:\n            handle_down = False\n            handle_count = 0\n            spl.trigger(-1, RELEASE_SLOT, True)\n            marker_release = RELEASE_SLOT\n            report('release')\n    else:\n        handle_count = 0\n# ---- end fxmic additions ----\n"

def patch(original: str) -> str:
    s = original
    def replace_once(old, new, what):
        nonlocal s
        if old not in s:
            sys.exit(f"cannot find the {what} in TE's script; firmware layout changed, see PLAN.md")
        s = s.replace(old, new, 1)
    replace_once("def python_callback(message):\n    #print(f\"callback {message:08x}\")",
                 ADDITIONS + "\ndef python_callback(message):\n    global handle_down, handle_count, marker_release, canceled_this_squeeze\n    #print(f\"callback {message:08x}\")",
                 "callback definition")
    replace_once("                sam_pos = sam_pos + 1\n                if sam_pos >= 4:\n                    sam_pos = 0\n                ui.leds(fx_pos,sam_pos)",
                 "                sam_pos = sam_pos + 1\n                if sam_pos >= 1:        # fxmic: slots 2-4 are markers (cancel, press, release); the play button stays on slot 1\n                    sam_pos = 0\n                ui.leds(fx_pos,sam_pos)",
                 "sample select cycling")
    replace_once("    if mess_type == 3:\n        if fx_primed > 0:",
                 "    if mess_type == 3:\n        handle_update(ui.handle())\n        shake_update()\n        modifier_update()\n        usb_update()\n        if marker_release >= 0:\n            spl.trigger(-1, marker_release, False)\n            marker_release = -1\n        if fx_primed > 0:",
                 "tick handler")
    # Claude mode keeps its config.json and marker sounds in /fat/claude, so the disk root stays factory for stock mode.
    replace_once("        os.chdir('/fat')\n",
                 "        os.chdir('/fat/claude')   # fxmic: Claude mode's config.json and samples live here\n",
                 "working directory")
    return s

def warn_old_firmware(machine: str):
    """Firmware 1.0.9 to 1.1.1 cannot load custom samples from config.json (TE's 1.1.2 notes: "fix regressions since
    1.0.9 parsing user json file"); the marker sounds then never play and squeezes go unnoticed."""
    try:
        version = tuple(int(p) for p in machine.split()[-1].split("."))
    except (ValueError, IndexError):
        print(f"note: could not read the firmware version from {machine!r}; 1.1.2 or later is required")
        return
    print(f"mic firmware: {'.'.join(map(str, version))}")
    if version < (1, 1, 2):
        print("WARNING: firmware older than 1.1.2 does not load the marker sounds from config.json.\n"
              "         Update first: https://teenage.engineering/downloads/ep-2350")

def main():
    args = sys.argv[1:]
    here = os.path.dirname(os.path.abspath(__file__))
    if args[:1] == ["--from-file"] and len(args) == 2:
        original = open(args[1]).read()
    elif args[:1] == ["--from-device"]:
        sys.path.insert(0, here)
        from mp_exec import open_port, raw_exec
        fd = open_port()
        version, _ = raw_exec(fd, "import sys\nprint(sys.implementation._machine)", 10)
        out, err = raw_exec(fd, "f=open('/rom/main.py')\nwhile True:\n b=f.read(512)\n if not b: break\n print(b, end='')\nf.close()", 30)
        os.close(fd)
        if out is None or (err and err.strip()): sys.exit(f"could not read /rom/main.py from the mic: {err}")
        # The console turns every "\n" into "\r\n"; without this the anchors below never match.
        original = out.replace("\r\n", "\n")
        warn_old_firmware((version or "").strip())
    else:
        sys.exit(__doc__)
    patched = patch(original)
    dst = os.path.join(here, "..", "firmware", "fxmic", "main.py")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    open(dst, "w").write(patched)
    print(f"wrote {os.path.relpath(dst)} ({len(patched)} bytes) from a {len(original)}-byte original")

if __name__ == "__main__":
    main()
