# fx-mic-claude

Push-to-talk into Claude with a Teenage Engineering EP-2350 FX mic. Squeeze the handle from any app, talk, release,
and your words land in the Claude desktop app as your own message. No cable to the mic, no hotkeys, no waiting for a
pause. A menu bar app on the Mac does the listening and transcription; a small script on the mic's own disk turns the
handle and a shake into marker tones that ride the audio line.

Built and tested on a MacBook Pro (M4, macOS 26) with an EP-2350 on OS 1.1.2, connected either through a TRS-to-TRRS
adapter into the headphone jack or through a Sabrent AU-UCMA USB audio adapter. Personal project, MIT licensed.
Nothing from Teenage Engineering is redistributed here.

## What it does

| You do | What happens |
| --- | --- |
| squeeze the handle, talk, release | the message is sent the moment you release, pauses included, no time limit |
| shake the mic hard while squeezing | the message is canceled, nothing is sent |
| tap the play button, handle released | the Claude window comes forward; tap again to go back |
| two quick taps, handle released | the app hangs up (stops listening, orange dot off) |
| left-click the menu bar handset | pick up or hang up |
| right-click the menu bar handset | menu: stop/start listening, input device, target session, shake to cancel, activity badge, launch at login, quit |
| `⌃⌥Space` | pick up or hang up |

English and Spanish are both recognized, chosen per message. The app hangs up by itself after 20 minutes without a
squeeze, which is when the mic turns itself off too. A small toast slides down from the top of the screen while you squeeze, showing "Listening" and a level
meter, switches to "Sending…" when you release and "Sent" when it lands, then slides away; it never takes focus.
The menu bar handset then follows the session you sent to: three pulsing dots in its corner while Claude works, a
check for two seconds when it finishes.

## How it works

The EP-2350 puts nothing on the wire except sound: its USB-C port is power and a disk, and its only output is a
3.5 mm line out. Worse, the mic outputs digital silence whenever you are quiet, squeezed or not, so a Mac listening to
the audio cannot tell a pause from a release. The mic runs MicroPython, though, and executes a `main.py` from its
disk at boot in place of the built-in startup. So:

1. **On the mic** (`firmware/`): a startup script that is TE's own script plus a few additions. On the 60 Hz tick it
   reads the handle position and the accelerometer, and plays short sample tones: 17 + 18.5 kHz when the handle passes
   half travel, 14 + 15 kHz when it is released, 12 + 13 kHz when the mic is shaken hard while squeezed. The play
   button plays a 15.5 + 16.5 kHz chirp. All four are one-shot samples on the mic's four sample slots.
2. **On the Mac** (`Sources/`): the FXMic menu bar app taps the audio input device by its identifier (the Sabrent, not
   the system default input), detects the tones with Goertzel filters, and treats the press marker as "message
   starts" and the release marker as "message ends". Speech in between goes to Apple's on-device speech recognizer,
   two locales at once (en-US and es-MX), and the more confident transcript wins about 100 ms after release. Tones
   are above 8 kHz and vanish in the recognizer's 16 kHz resampling.
3. **Into Claude**: the app sets the text of the Claude desktop app's composer through the Accessibility API and
   presses its Send button, never touching focus, so the message appears as one you typed. A typed draft in the
   composer is set aside and restored. Without Accessibility access it falls back to a file inbox that a Claude Code
   session watches after running `/fxmic`.

`PLAN.md` is the engineering log with every measurement and dead end (pilot tones, hold playmode, silence timeouts,
the boot-order discovery and the crash it caused).

## What you need

- A [Teenage Engineering EP-2350 FX mic](https://teenage.engineering/store/ep-2350) (tested on OS 1.1.2, [guide](https://teenage.engineering/guides/ep-2350)) with two AAA batteries.
- A Mac running macOS 26 with the Xcode command line tools installed (`xcode-select --install`).
- A way to feed the mic's 3.5 mm line output into the Mac as a microphone input. Two options are tested:

| option | what it is | pros | cons |
| --- | --- | --- | --- |
| **Headphone jack** (Miguel's daily setup) | a TRS-to-TRRS adapter such as the [Movo MC3](https://www.amazon.com/dp/B01N9CJDVE) from the mic's 3.5 mm cable straight into the MacBook's headphone jack | nothing else to carry, no USB port used, shows up as "External Microphone" | the moment it is plugged in, macOS also moves sound **output** to the jack, so pick "MacBook Pro Speakers" again under System Settings > Sound > Output (or in the Control Center sound menu). Once per plug-in. |
| **USB audio adapter** | a USB-C dongle with a 3.5 mm mic input, such as the Sabrent AU-UCMA ([Amazon](https://www.amazon.com/dp/B0DGMVFY85), [Sabrent](https://sabrent.com/products/au-ucma)), shows up as "USB Advanced Audio Device" | speakers untouched, works on any Mac | one more dongle and a USB-C port |

- A 3.5 mm TRS cable from the mic's line out to the adapter (any stereo 3.5 mm male-to-male cable).
- A USB-C data cable for the mic, needed only while installing the script on the mic (a couple of minutes, once).
- The mic's line out is loud (2 Vrms). Set its orange volume knob under the lid low. The app trims the input gain
  after each message and both adapters ended up in the right range on their own.

## Setup

### 1. The Mac app

Requires macOS 26 (Apple's SpeechAnalyzer) and the Xcode command line tools. No Xcode project.

```
tools/make_signing_identity.sh        # once: a local self-signed identity so permission grants survive rebuilds
tools/make_app.sh                     # builds, signs, installs ~/Applications/FXMic.app
open ~/Applications/FXMic.app
```

On first launch grant Microphone when asked, then use the menu's "Grant Accessibility access…" (System Settings >
Privacy & Security > Accessibility) so messages can go into Claude's composer. Right-click the handset for the menu:
Start/Stop listening, Input device, Target, Shake to cancel, Menu bar activity badge, Launch at login, Quit. "Target" shows, by name, the session that
will receive the next message: by default the one you used last. The submenu lists your five most recently used
sessions; pick another and the next message goes there even while a different session is on screen (the app switches
the sidebar row before typing, no focus change), and that session then counts as the last used. Under "Input device" pick "External Microphone"
for the headphone-jack adapter or "USB Advanced Audio Device" for the Sabrent; picking one starts listening on it.
Left-click the handset to hang up or pick up.

The recognizer models for en-US and es-MX are installed on first use by the app (Apple system assets). Change the
locales with `defaults write com.miguel.fxmic locales -array en-US es-MX`.

### 2. The mic

Power the mic on, connect its USB-C port to the Mac; a drive called "FX MIC DISK" mounts and a serial console appears.

```
tools/build_fxmic_script.py --from-device     # reads TE's startup script from your mic and writes the patched copy
tools/install_disk.sh install                 # copies main.py, fxmic.py and the four marker sounds to the disk
```

Eject the disk, unplug, power the mic off with the small button above the USB port, squeeze to start. Done: the
script runs on every boot from now on. `tools/install_disk.sh remove` deletes the two files and the mic is stock again
(the sounds can stay, or delete `config.json` and the `.wav` files to get the horn and applause back).

Do not use `mpremote` or any pyserial-based tool on the mic's serial port: opening the port with modem-line toggling
resets the mic. `tools/mp_exec.py` runs code over the raw REPL without that.

### 3. Claude

With Accessibility granted, spoken messages go to whatever Claude view is open, chat or Code session. Without it, run
`/fxmic` in a Claude Code session to receive messages through the file inbox at `~/.fxmic/inbox/`; the skill is in
`claude/skills/fxmic/SKILL.md`, copy it to `~/.claude/skills/fxmic/`.

## Tools

| tool | purpose |
| --- | --- |
| `fxmic-cal` (Swift, `swift build -c release`) | calibration: live levels, tone scan, gate and gesture events, utterance recordings, `--stt` transcription, `--file` offline replay |
| `tools/mp_exec.py` | run Python on the mic over the raw REPL without resetting it |
| `tools/build_fxmic_script.py` | patch TE's startup script with the marker and shake logic |
| `tools/install_disk.sh` | install or remove the script and sounds on the mic's disk |
| `tools/make_marker_pack.py` | generate the four marker sounds and `config.json` |
| `tools/romfs_deploy.py` | write a ROMFS image to the mic's read-only script partition (not needed for the disk route) |
| `tools/make_escape_uf2.py` | build the recovery UF2 that blanks the disk |
| `tools/probe_*.py`, `tools/serial_probe.py`, `tools/repl.py` | the probes used to learn the handle, accelerometer, and boot behavior |

Debug hook: `echo "hello" > ~/.fxmic/send.txt` delivers text as if spoken. Log at `~/.fxmic/fxmic.log`, state at
`~/.fxmic/state.json`.

## Troubleshooting and recovery

- **Nothing happens when you squeeze**: the app is idle (left-click the handset), or the input device is wrong
  (right-click, "Input device": "External Microphone" for the jack adapter, "USB Advanced Audio Device" for the
  Sabrent), or the mic script is not installed (`tools/install_disk.sh install`).
- **No sound from the Mac after plugging the jack adapter in**: macOS moved output to the jack. System Settings >
  Sound > Output > MacBook Pro Speakers.
- **Messages arrive as system notes instead of your bubbles**: Accessibility is not granted, or the Claude window is
  closed. Check `~/.fxmic/fxmic.log` for "composer delivery failed".
- **False cancels or shakes not registering**: the shake rule needs three alternating swings of about 0.4 g within 550 ms, and it can be switched off in the menu. Tune
  `SHAKE_DEV`, `SHAKE_EXCURSIONS`, `SHAKE_WINDOW` in `tools/build_fxmic_script.py` and reinstall.
- **The mic does not start after a bad script**: hold the handle and double-click the small button above the USB port,
  drag `firmware/te/escape_blank_disk.uf2` onto the "FX MIC BOOT" drive. The disk is reformatted at the next start
  and the mic runs its built-in startup. TE's firmware is at https://teenage.engineering/downloads/ep-2350 if you need
  a full reflash; it does not touch the disk region.

## Repository layout

```
Sources/FXMicCore   audio device tap, speech gate, Goertzel tone detection, live dual-locale transcriber, WAV writer
Sources/FXMic       the menu bar app: controller, HUD, status menu, composer delivery, dispatcher, hotkey, settings
Sources/fxmic-cal   calibration command line tool
firmware/           boot stub, patched-script builder inputs, recovery UF2, notes
packs/              generated sample packs (marker-pack is the one in use)
tools/              scripts listed above
claude/             the /fxmic skill for Claude Code
PLAN.md             engineering log
```

## License

MIT for everything in this repository. The EP-2350 firmware, its startup script, and its documentation belong to
Teenage Engineering and are not included; the build tool reads the script from your own device.
