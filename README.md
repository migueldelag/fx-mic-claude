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
| press orange (FX) while squeezing | queue: the message waits until the Claude session finishes its turn, then is sent |
| press white (sample) while squeezing | draft: the message is added to the composer, after any text already there, and not sent |
| tap the play button, handle released | the Claude window comes forward; tap again to go back |
| two quick taps, handle released | the app hangs up (stops listening, orange dot off) |
| left-click the menu bar handset | pick up or hang up |
| right-click the menu bar handset | menu: stop/start listening, input device, target session, shake to cancel, activity badge, launch at login, quit |
| `⌃⌥Space` | pick up or hang up |

English and Spanish are both recognized, chosen per message. The app hangs up by itself after 20 minutes without a
squeeze, which is when the mic turns itself off too. A small toast slides down from the top of the screen while you squeeze, showing "Listening", a level
meter and the live transcript, all of it, growing downward as you talk. It switches to "Sending…" when you release and
"Sent" with the final text when it lands, then slides away; it never takes focus.
The live text comes from a second, faster recognizer: first words about 1 s after you start talking, then about once a
second. The sent text still comes from the accurate recognizer. Settings (`defaults write com.miguel.fxmic …`, then
restart FXMic): `hudTranscript -bool false` hides the text, `livePreview -bool false` drops the fast recognizer (live
text then arrives in bursts a few seconds late), `fastLiveText -bool true` makes every recognizer fast, the sent text
included, at some cost in accuracy.

Queue and draft show in the toast as soon as the button is pressed ("Listening · Queue" with an orange clock,
"Listening · Draft" with a blue pencil). Pressing the other button later in the same squeeze switches; the last one
pressed wins. On release the toast reads "Queueing…" or "Adding to draft…" instead of "Sending…". A queued message
goes out as soon as the session is idle, so it is sent right away when Claude is not working. Queued messages go one
at a time, at least 10 s apart; one still waiting after 30 minutes is left in the composer as a draft. Whether a session
is working is read from the desktop app's own session files (`latestUserFrameAt` newer than `lastTurnEdgeAt`), an
undocumented detail that may change.
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

- A [Teenage Engineering EP-2350 FX mic](https://teenage.engineering/store/ep-2350) on firmware 1.1.2 or later ([guide](https://teenage.engineering/guides/ep-2350), [downloads](https://teenage.engineering/downloads/ep-2350)) with two AAA batteries. Firmware 1.0.9 to 1.1.1 cannot load the marker sounds from `config.json`, so squeezes go unnoticed; `tools/build_fxmic_script.py --from-device` prints the version and warns.
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
tools/install_disk.sh install                 # boot stub as main.py; fxmic.py, config.json and the markers in claude/
```

Eject the disk, unplug, power the mic off with the small button above the USB port, squeeze to start. Done: the
script runs on every boot from now on. `tools/install_disk.sh remove` deletes `main.py` and `claude/` and the mic is
stock again.

**Switching modes on the mic.** Claude mode keeps its files in `claude/`, so the disk root stays factory. To switch
between Claude mode and stock (factory effects and sounds, no marker beeps, for example to use the mic with a
K.O. II): with the mic on and the handle released, hold the orange FX button for 3 seconds for Claude mode, or the
white sample button for 3 seconds for stock. The sample LEDs sweep up three times for Claude or down three times for
stock (also when it already was in that mode), and the mode is saved in `claude/mode`. Turn the mic off and on to
start in that mode. The hold also steps the FX preset or sample once, like any press; that resets at the restart.
TE's own script gives these buttons no long-press action, and its button combinations (white + grey for recovery,
handle + double-click for the bootloader) only apply while powering on.

Do not use `mpremote` or any pyserial-based tool on the mic's serial port: opening the port with modem-line toggling
resets the mic. `tools/mp_exec.py` runs code over the raw REPL without that.

### 3. Claude

With Accessibility granted, spoken messages go to whatever Claude view is open, chat or Code session. Without it, run
`/fxmic` in a Claude Code session to receive messages through the file inbox at `~/.fxmic/inbox/`; the skill is in
`claude/skills/fxmic/SKILL.md`, copy it to `~/.claude/skills/fxmic/`.

**Claude's own dictation (optional, recommended for accuracy).** By default FXMic transcribes with Apple's
on-device recognizer. Turn on "Transcribe with Claude's dictation" in the menu (or
`defaults write com.miguel.fxmic transcriptionEngine claude`) and a squeeze drives the Claude app's own dictation
instead: FXMic presses the mic control next to the composer ("Press and hold to record") through Accessibility,
presses it again on release, and leaves the text where Claude wrote it, in the session it was spoken into: white
keeps it as a draft, a plain squeeze presses Send (or queues when the session is busy), orange queues it in
Claude with Cmd+Return. Like dictating by hand, the words are added after any draft already in the composer, and
Send sends both. That is the same speech-to-text as clicking the mic in Claude, so the words come out
the same. Apple's recognizer keeps running alongside as the fallback when dictation cannot start, and the log shows
both transcripts of every message ("compare: claude: … | apple …"). The Claude window has to show a composer
with the mic control. Claude starts listening 0.4 to 1 s after the squeeze, so wait for "Listening" in the bar
before talking. If Claude renames the control, list what is next to the composer with `touch ~/.fxmic/axdump`
(written to the log) and set `defaults write com.miguel.fxmic dictationButtonLabels -array "<part of the label>"`.

## Band-limited or quiet adapters

The default markers sit at 12 to 18.5 kHz. Some cheap USB-C audio dongles sample their mic input at a low internal
rate and pass nothing above about 7 kHz; one measured here ("AB13X USB Audio") was flat to 6 kHz, 20 dB down at
7 kHz, and silent above. Squeezes then go unnoticed while speech still arrives. Check with
`.build/release/fxmic-cal --device "<name>" --scan` while squeezing: no scan lines above 12 kHz means the tones are
filtered out.

- Use the low-pitch markers (3.4 to 5.7 kHz, regenerate with `tools/make_marker_pack_lowband.py`):
  `tools/install_disk.sh install marker-pack-lowband`, then run the four `defaults write com.miguel.fxmic … -array …`
  commands it prints so FXMic listens for the same pitches, and restart FXMic. `tools/install_disk.sh install` and
  `defaults delete` on those keys go back to the originals.
- If the input is quiet (the "quiet, turn the orange knob up" hint with the knob already at maximum), lower the
  thresholds: `defaults write com.miguel.fxmic chirpMinLevelDb -float -85` for the markers and
  `defaults write com.miguel.fxmic openDb -float -60` so speech still counts, then restart FXMic. The log line
  "tone threshold … speech threshold …" shows the values in use.
- If quiet speech is often misheard, raise the level fed to the recognizer only:
  `defaults write com.miguel.fxmic transcriberGainDb -float 20`. On recordings peaking at -36 to -43 dBFS, +20 dB raised
  the confidence of weaker sentences from 0.75-0.79 to 0.87-0.88. The meter, speech gate and markers are unaffected.

## Tools

| tool | purpose |
| --- | --- |
| `fxmic-cal` (Swift, `swift build -c release`) | calibration: live levels, tone scan, gate and gesture events, utterance recordings, `--stt` transcription, `--file` offline replay, `--tones "press=17000,18500;release=14000,15000"` and `--min-level -60` to test other markers and thresholds |
| `tools/mp_exec.py` | run Python on the mic over the raw REPL without resetting it |
| `tools/build_fxmic_script.py` | patch TE's startup script with the marker and shake logic |
| `tools/install_disk.sh` | install (optionally another marker pack) or remove the script and sounds on the mic's disk |
| `tools/make_marker_pack_lowband.py` | marker tones at 3.4-5.7 kHz plus `pitches.json`, for adapters that cut everything above ~7 kHz |
| `tools/make_marker_pack.py` | generate the four marker sounds and `config.json` |
| `tools/romfs_deploy.py` | write a ROMFS image to the mic's read-only script partition (not needed for the disk route) |
| `tools/make_escape_uf2.py` | build the recovery UF2 that blanks the disk |
| `tools/probe_*.py`, `tools/serial_probe.py`, `tools/repl.py` | the probes used to learn the handle, accelerometer, and boot behavior |

Debug hooks, set as environment variables when launching (`open --env NAME=value ~/Applications/FXMic.app` keeps the
app's own permissions): `FXMIC_RECORD=/path/live.wav` saves exactly what FXMic hears until it hangs up, to compare
with `fxmic-cal` recording the same device; `FXMIC_REPLAY=/path/take.wav` feeds a recording through the live pipeline
(markers, transcription, delivery) 3 s after it starts listening. The log has a "tone <name> level … snr …" line
for every marker onset.

Debug hook: `echo "hello" > ~/.fxmic/send.txt` delivers text as if spoken. Log at `~/.fxmic/fxmic.log`, state at
`~/.fxmic/state.json`.

## Troubleshooting and recovery

- **Nothing happens when you squeeze**: the app is idle (left-click the handset), or the input device is wrong
  (right-click, "Input device": "External Microphone" for the jack adapter, "USB Advanced Audio Device" for the
  Sabrent), or the mic script is not installed (`tools/install_disk.sh install`).
- **Speech arrives but squeezes are never detected (no "handle pressed" in the log)**: check FXMic's Mic Mode.
  While FXMic is listening, open Control Center > Mic Mode and choose Standard. Voice Isolation keeps speech and
  silences the marker tones a few milliseconds after they start, so nothing else looks wrong. macOS remembers the mode
  per app; FXMic logs "mic mode: …" and warns and opens the picker when Voice Isolation is active. Also check the
  firmware (1.1.2 or later), and that your adapter passes the 12 to 18.5 kHz tones: run
  `.build/release/fxmic-cal --device "<name>" --scan` while squeezing; no scan lines above 12 kHz means it filters them out.
- **No sound from the Mac after plugging the jack adapter in**: macOS moved output to the jack. System Settings >
  Sound > Output > MacBook Pro Speakers. Switching output while listening knocks the audio engine off the
  jack input; the app notices within a second and rebinds it (log lines "engine drifted" and "reconnected"). Unplugging the adapter or the mic while
  listening hangs up; pick up again after plugging back in.
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
