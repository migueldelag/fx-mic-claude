# fx-mic-claude: notes for Claude Code

This repo turns a Teenage Engineering EP-2350 FX mic into push-to-talk input for the Claude desktop app on macOS.
If the user asks you to install or set it up, follow the runbook below. It is a Swift package (no Xcode project),
a few Python and zsh tools, and a script that goes on the mic's own disk. Read `README.md` for the full picture.

## Runbook: install from scratch

Tell the user what you are doing at each step; steps marked HUMAN need their hands.

1. Prerequisites: macOS 26 or newer (`sw_vers`), Xcode command line tools (`xcode-select -p`; if missing,
   HUMAN runs `xcode-select --install`), Python 3 (system one is fine). The mic's 3.5 mm output must reach a
   microphone input on the Mac: a TRS-to-TRRS adapter in the headphone jack ("External Microphone") or a USB audio
   adapter such as the Sabrent AU-UCMA ("USB Advanced Audio Device"). Check with
   `.build/release/fxmic-cal --list` after building.
2. Build and install the app:
   ```
   tools/make_signing_identity.sh      # once per Mac; a self-signed identity so permission grants survive rebuilds
   tools/make_app.sh                   # builds, signs, installs ~/Applications/FXMic.app
   open ~/Applications/FXMic.app
   ```
3. HUMAN, in this order: allow Microphone when macOS asks; right-click the handset in the menu bar and choose
   "Grant Accessibility access…", then enable FXMic in System Settings > Privacy & Security > Accessibility; in the
   same menu pick the right "Input device" and turn on "Launch at login". If the headphone-jack adapter is used,
   macOS moves sound output to the jack: HUMAN reselects the speakers under System Settings > Sound > Output.
4. Verify the Mac side without the mic: `echo "hello from fxmic" > ~/.fxmic/send.txt`. Within two seconds the text
   must appear as a sent message in the Claude window. If it lands nowhere, read `~/.fxmic/fxmic.log`.
5. Install the script on the mic. HUMAN: put batteries in, squeeze the handle once so it powers on, connect the
   mic's USB-C port to the Mac with a data cable. Wait until `/dev/cu.usbmodem*` exists and a volume named
   "FX MIC DISK" is mounted (`ls /dev/cu.usbmodem* /Volumes`). Then:
   ```
   tools/build_fxmic_script.py --from-device    # reads TE's startup script from THIS mic and writes firmware/fxmic/main.py
   tools/install_disk.sh install                # copies main.py, fxmic.py and the four marker sounds to the disk
   diskutil eject "/Volumes/FX MIC DISK"
   ```
   HUMAN: unplug the cable, press the small button above the USB port (power off), squeeze to start. The script
   now runs on every boot.
6. Verify end to end. HUMAN squeezes, says a sentence, releases. The toast shows Listening, then Sending…, then
   Sent, and the words appear in Claude as the user's message. A hard shake while squeezing cancels. A tap on the
   play button with the handle released brings Claude forward.

## Hard-won rules

- Never touch the mic's serial port with `mpremote`, `pyserial`, `screen`, or anything that toggles DTR/RTS: it
  resets the mic and drops it off USB. Use `tools/mp_exec.py` (raw REPL over a plain file descriptor).
- `/fat/main.py` on the mic's disk REPLACES Teenage Engineering's startup. The stub in `firmware/fxmic/boot_main.py`
  must stay exactly in this order: `import ui; ui.callback(0)` first (a stale tick callback otherwise floods errors or
  hard-faults after a soft reset), then add `/fat` to `sys.path`, then `import fxmic`. Removing `main.py` and
  `fxmic.py` from the disk returns the mic to stock.
- Writing files to the mic's disk over the console can fail with EIO and leave a truncated file. Prefer copying from
  the Mac while the disk is mounted (`tools/install_disk.sh`); if you must write over the console, write 400-byte
  flushed pieces and verify size and checksum.
- If a bad script ever stops the mic from starting: HUMAN holds the handle and double-clicks the small button above
  the USB port; a drive "FX MIC BOOT" appears; drag `firmware/te/escape_blank_disk.uf2` onto it. The disk is
  reformatted at the next start. TE's firmware (not in this repo) is at https://teenage.engineering/downloads/ep-2350.
- Teenage Engineering's script, README, PDF, samples and firmware are copyrighted and git-ignored. Never commit them.
  `firmware/fxmic/main.py` is generated locally from the user's own device.
- The app runs as a menu bar item. Rebuild and relaunch with `tools/make_app.sh && pkill -x FXMic; open ~/Applications/FXMic.app`.
  Logs: `~/.fxmic/fxmic.log`; state: `~/.fxmic/state.json`.
- Composer delivery works through the Accessibility API: it sets the composer text and presses the button labeled
  "Send", never one labeled "Stop". Session targeting presses the sidebar row titled "Idle <title>" or
  "Running <title>"; the active session is the header button described "<title>, rename session".

## Layout

`Sources/FXMicCore` (audio, tone detection, transcription), `Sources/FXMic` (menu bar app), `Sources/fxmic-cal`
(calibration CLI), `firmware/` (mic script builder inputs and recovery UF2), `packs/` (marker sounds), `tools/`,
`claude/skills/fxmic` (optional inbox fallback skill), `PLAN.md` (engineering log with every dead end).
