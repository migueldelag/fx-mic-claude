# fx-mic-claude

Push-to-talk into Claude with the Teenage Engineering EP-2350 FX mic. Squeeze the handle from any app, talk, release, and the text lands in the Claude Code session working on the current project. A menu bar app does the listening.

## Decisions (Miguel, 2026-09-12)

- Default destination: the running Claude Code session. Chat is secondary.
- Send immediately on release. No preview step. HUD shows what was sent.
- No screenshots for now.
- Languages: English and Spanish (Mexico), mixed.
- Samples: all four slots get the same control chirp, so the grey button is the only actionable button. Single tap and double tap, combined with handle open or closed.
- macOS default input stays the MacBook mic. The app taps the Sabrent directly by device UID.
- The orange "mic in use" indicator should not be lit all day. See "Indicator".
- Orange volume knob is reachable. Calibrate as needed.

## Hardware facts

- EP-2350 output is analog only: 3.5 mm line out, max 2 Vrms, into the Sabrent AU-UCMA mic jack. macOS sees the Sabrent as "USB Advanced Audio Device", mono, 48 kHz.
- The mic's USB-C port is power and a mass storage disk only. No USB audio, MIDI, or HID. Nothing on the Mac can see the handle or buttons except through the audio.
- Handle released: line is digital silence, measured at about -84 dBFS RMS.
- Confirmed by Miguel: grey plays samples without the handle held; no clipped first word when squeezing from idle.
- Buttons: orange cycles FX presets, white cycles sample slot, grey fires the sample. Only grey makes sound.
- Disk: hold the handle and double-click the small button above the USB port while connected to the Mac over USB-C. Volume mounts as "fx-mic disk". Samples are 1.wav to 4.wav, WAV only, 1 MB total. Optional config.json for playmodes, FX chains, handle, shake, LFO. Eject to restart the mic.

## Gesture grammar

| Handle | Grey | Meaning |
| --- | --- | --- |
| squeeze, talk, release | none | send transcript to the current target session |
| released | single tap | bring the Claude app to the front; tap again to go back to the previous app |
| released | double tap | stop listening: mic closed, indicator off. Resume with ⌃⌥Space or the menu bar icon |
| squeezed | shake hard | cancel this message, nothing is sent |
| squeezed | single tap | nothing |

New Code session is a menu bar item, not a gesture: the folder confirmation dialog makes it a bad surprise, and triple taps were unreliable because fast presses re-trigger the same chirp.

Double tap = two chirps within 450 ms. Single tap resolves 450 ms after the first chirp.

## Architecture

Native Swift, one SwiftPM package. No Xcode needed, builds with the command line tools.

1. Listener. AVAudioEngine tap on the Sabrent selected by UID. 10 ms hops. The handle is read from the noise floor: released is digital silence, squeezed is room noise. Squeeze starts the message, release sends it. A speech gate inside the window only decides whether anything was said.
2. Chirp detector. Goertzel filters at the control tone frequencies, guard bands for SNR, tap and double-tap grouping.
3. Transcriber. whisper.cpp large-v3-turbo with Metal, language auto-detect, bilingual initial prompt. Chosen over Apple's on-device SpeechAnalyzer because Apple's runs one locale per session and we need mixed English and Spanish. Utterances are short, so a rolling decode every second gives a near-live transcript. Engine is behind a protocol so Apple or Parakeet can be benchmarked later. Whisper resamples to 16 kHz, so tones above 8 kHz vanish before decoding.
4. HUD. Non-activating floating NSPanel at top center: level meter, live transcript, target name. Never takes focus. Menu bar icon shows idle, listening, sent, with a menu for target, history, settings.
5. Dispatcher. Writes each utterance to the target's inbox file. Opens `claude://code/new?folder=...` for new sessions. Activates the Claude app for the single tap.

### Session protocol (`~/.fxmic/`)

```
targets/<target-id>.json   {id, title, cwd, armedAt}      written by the /fxmic command
inbox/<target-id>.jsonl    {ts, text, lang}               appended by the app on release
outbox/<target-id>.jsonl   {ts, status, note}             appended by the session when done (optional, for HUD feedback)
state.json                 current target, armed or idle  written by the app
```

`/fxmic` is a user-level slash command. It registers the session as a target and starts a persistent Monitor on that session's inbox. Each new line arrives in the session as an event and is treated as a spoken message from Miguel. The inbox is a local file written only by the app.

## Indicator

macOS lights the orange dot whenever any process has an audio input running. No app can suppress it, virtual devices included. The only lever is when the input is open.

Plan: the app listens only while armed. Arming happens from `/fxmic`, the menu bar icon, or a hotkey. It goes idle after 10 minutes without speech and when no target is armed. Idle means the input is closed and the dot is off.

Options if that is not enough:
- USB wake: if the mic enumerates as a USB device when powered on, its appearance and disappearance can arm and disarm the listener. Needs a test with the mic on a USB-C data cable.
- Hardware sidecar: a small microcontroller on a Y-split of the line out that reports the mic gate as a USB HID key. The app opens the input only while the key is down. Dot only while speaking. Later, if wanted.

## Milestones

1. Calibration CLI: device tap by UID, gate, chirp scan, recordings. Done 2026-09-12. All test tones from 12 to 18.5 kHz pass with 50 dB or more of margin; taps and double taps detected.
2. Menu bar app: arm and idle, HUD with meter and live transcript, Apple on-device transcription in en-US and es-MX picked by confidence. Built 2026-09-12 (`build/FXMic.app`, `tools/make_app.sh`). whisper.cpp dropped: Apple finalizes in 0.1 to 0.3 s and picked the right language on every test recording.
3. Dispatch: inbox protocol, `/fxmic` skill at `~/.claude/skills/fxmic/SKILL.md`, tap, double tap, hold, and cancel. Built 2026-09-12, end-to-end test pending.
4. Final sample pack: `packs/claude-pack/` (one 17 + 18.5 kHz hold-mode chirp on all four slots, dry presets). Generated, not yet loaded on the mic.
5. Polish: launch at login, settings UI, outbox feedback in the HUD, gain management for the Sabrent input, sounds.

## Findings so far

- 2026-09-12, from the readme.pdf on the mic's disk: firmware is MicroPython on a Raspberry Pi Pico (Pico SDK + MicroPython licenses). Powered on over a USB-C data cable the mic enumerates as a composite device: CDC serial (`/dev/cu.usbmodemEPXYW3YH1`), plus mass storage "FX MIC DISK" (1 MB) that mounts without any button combo. The button above the USB port is power off; the handle powers on. Firmware disk "FX MIC BOOT" needs hold handle + double-click that button.
- Readme button names: orange = clean voice + 4 FX presets [clean, echo, spring, pixie, robot]; green = select sample [horn, claps, bell, f*k]; white = play sample. The mic capsule is enabled only while the handle is pushed.
- config.json extras not in the web guide: sample `"duck": 1.0` mutes the voice while a sample plays (that is how the censor works), preset `"trigger": { "row": N }` picks which SAMPLE row the play button fires, LFO `"mpy"`. Recovery: hold green + white while starting if a config prevents boot. New samples need a restart: power off with the small button, squeeze to start.
- Factory disk holds only `4_.wav` (stereo 32 kHz, 3.6 s) and readme.pdf, no config.json. Backed up in factory-pack/ together with the BOOT drive files Miguel copied (INDEX.HTM, INFO_UF2.TXT).
- Session 2 audio: voice peaks at 0 dBFS with under 0.3 percent clipped samples, horn peaks at -6 dBFS, squeeze precursor visible 40 to 50 ms before speech. Apple on-device transcription of the recordings took about 0.1 s per sentence; en-US and es-MX models are installed.

- 2026-09-12: calibration CLI built and verified offline on a synthetic sequence: single, double, and triple taps group correctly with a rolling 450 ms window. Live test pending, the Sabrent was unplugged at the time.
- A chirp with the handle released also opens the speech gate for about 0.85 s. The app must drop utterances that contain nothing but chirp frames before sending anything to the transcriber.
- Engine choice changed to whisper.cpp because of the English plus Spanish requirement.

## Running it

- `tools/make_app.sh && open build/FXMic.app` builds and launches the menu bar app. First launch asks for microphone access.
- Left-click the menu bar handset to pick up or hang up (toggle listening); right-click or control-click for the menu. `⌃⌥Space` also toggles. Idle (hang up) after 20 minutes without a squeeze.
- In a Claude Code session, `/fxmic` arms it as the target. Utterances land in `~/.fxmic/inbox/<id>.jsonl`; the session watches it with a persistent Monitor.
- `~/.fxmic/fxmic.log` and `~/.fxmic/state.json` show what the app is doing.
- Gestures need the claude-pack on the mic: tap = Claude app front/back, double tap = stop listening, tap while talking = cancel. Hold mode was tried on 2026-09-13: presses came out as 0.8 to 1.8 s tones regardless of finger time, so the pack is one-shot.

## Verified end to end (2026-09-13, 00:30)

- Squeeze, talk, release: text arrives in the armed session within about a second of release. English and Spanish both picked correctly.
- Cancel: a tap mid-sentence discards the utterance; the next sentence arrives clean. Each utterance gets fresh analyzers, so nothing carries over.
- Message boundary: the EP-2350 outputs digital silence (-86 dBFS) whenever the voice is quiet, squeezed or not, measured in Miguel's own recordings. So the handle is invisible to the Mac during pauses. Current rule: a message starts on speech and is sent after 1.5 s of silence (`silenceSeconds`), 20 s cap. Proposed fix for exact handle semantics: a looping pilot tone whose level follows the handle via config.json modulation.
- Moving the mic without talking shows nothing. HUD only appears on sustained speech energy.
- Auto gain: the Sabrent input gain is nudged after each utterance to keep peaks between -20 and -4 dBFS.

## Firmware route (2026-09-13, 01:00 to 01:35)

- Handle markers work end to end: the mic's script triggers `press.wav` (17 + 18.5 kHz) when `ui.handle()` crosses 0.5 and `release.wav` (14 + 15 kHz) when it drops below 0.3, polled on the ~60 Hz tick message; the app opens the message on the press marker and sends on the release marker. Verified live with the script hot-loaded over the serial console: a sentence with a 3 s pause arrived as one message, sent 120 ms after release.
- `ui.handle()` reads 0.0 released to 1.0 squeezed with a clean 0.3 s ramp. ADC messages 0-4 in the callback are slow telemetry, not the handle.
- Persistence, solved 2026-09-13 01:40. Boot order is: frozen `_boot_fat`, then `/fat/main.py` if it exists, otherwise the frozen `teenage` module (TE's startup; `/rom/main.py` is only a reference copy). So a disk `main.py` replaces TE's startup entirely. Two hazards, both handled: (1) after a soft reset the C tick handler still holds the previous session's callback, and calls it until `ui.callback(0)` runs, which floods errors or hard-faults, so the stub clears the callback on its first line and only then imports the real script (compiling 8 KB from source would keep that window open); (2) the working directory at boot is `/`, so the stub adds `/fat` to `sys.path`. Install = `tools/install_disk.sh install` with the disk mounted; remove = `remove`. Never run the main.py-deleting recovery watcher while the hook is installed. Escape hatch if a boot ever loops: `firmware/te/escape_blank_disk.uf2` dragged onto "FX MIC BOOT" blanks the disk's first sectors so the firmware reformats it (TE's own firmware UF2 does not touch the disk region).
- Tools: `tools/mp_exec.py` (raw REPL exec that does not toggle DTR/RTS; pyserial/mpremote resets the mic), `tools/romfs_deploy.py` (ROMFS write through the block device in 512-byte pieces, readback-verified; the device heap is 64 KB, no `gc`, no `hashlib`). `/rom/main.py` was rewritten and then restored to TE's original (6599 bytes).
- TE firmware zips: https://teenage.engineering/_software/ep-2350/ep-2350_firmware_1_1_2.zip (installed version). Recovery via FX MIC BOOT (hold handle, double-click the small button). Whether a firmware reflash or the green+white recovery combo removes a disk `main.py` is unknown.
- Device state: stock firmware, `/rom` original, disk = `main.py` stub + `fxmic.py` + marker pack. Verified live: a sentence with a 3 s pause arrived as one message 190 ms after release. Cold-boot persistence confirmed 01:42 with no cable: one message with the pause inside, sent 160 ms after release.

## Composer delivery (2026-09-13, 02:00)

Spoken messages now appear as Miguel's own bubbles. On release the app sets the text of Claude's composer through the Accessibility API (the `AXTextArea` described "Prompt" in the main window) and presses the adjacent button only if it is labeled "Send" (it reads "Stop" while a turn runs and must never be pressed). No focus change, no clipboard, no key events. Electron publishes its accessibility tree only after `AXManualAccessibility` is set on the app element, which takes about 2 s the first time; the app warms it up when arming. If the composer holds a typed draft, the spoken message is still sent on its own and the draft is put back afterwards (Miguel: no review, always send unless canceled). Fallbacks in order: file inbox for an armed session, then clipboard. The `/fxmic` inbox remains useful for sessions that are not on screen.

Permission: FXMic needs Accessibility (System Settings > Privacy & Security > Accessibility). The menu offers "Grant Accessibility access…". Because the bundle is ad-hoc signed, a rebuild changes its identity and macOS may ask again; a stable signing certificate would fix that. Debug hook: writing text to `~/.fxmic/send.txt` delivers it as if spoken; the menu has "Send a test message to Claude".

## 2026-09-13 morning: handle only, minimal HUD, stable identity

- Speech without a press marker is ignored entirely. No silence rule. The handle is the only start and end of a message; a squeeze lighter than half travel does nothing even though the capsule opens.
- HUD shows only a title ("Listening", then a 0.8 s "Sent" or "Canceled"), the icon, and the level meter. No transcript, no target line. 260 pt wide.
- Signing: `tools/make_signing_identity.sh` creates a self-signed "FXMic Dev" identity in `~/Library/Keychains/fxmic-signing.keychain-db` (password in `~/.fxmic/signing-keychain.pw`); `tools/make_app.sh` signs with it and installs to `~/Applications/FXMic.app`, so Accessibility and Microphone grants survive rebuilds. First normal launch still asks once.
- "Launch at login" toggle in the menu (SMAppService). Debug hook: `echo text > ~/.fxmic/send.txt`.

## Shake to cancel (2026-09-13 afternoon)

- Cancel is a shake, not the button. The mic script reads the accelerometer on every tick and plays `cancel.wav` (12 + 13 kHz, slot 2) once per squeeze when the acceleration magnitude leaves one g (17400 counts) by more than 9000 counts in alternating directions at least four times within 25 ticks. Rotation keeps the magnitude at one g, so slow turns never count; single gestures produce one or two excursions, not four. The firmware's own `ui.shaker()` (0 to 1) reacts to orientation changes and gave false cancels.
- Tuning knobs in `firmware/fxmic/main.py`: `SHAKE_DEV`, `SHAKE_EXCURSIONS`, `SHAKE_WINDOW`. Probe data: rest 17000-17900 counts, moderate shake 13000-25000, hard shake 8400-56700 (sensor saturates at 32752 per axis).
- The play button is inert while the handle is squeezed. The select button is pinned to slot 1 (chirp); slots 2-4 are markers.
- Writing files to the mic's FAT over the console can fail with EIO and leave a truncated file; write in 400-byte flushed pieces and verify size and checksum (`tools` pattern in this session), or copy from the Mac while the disk is mounted.

## Input adapters

- Sabrent AU-UCMA (USB): works, separate device, speakers unaffected. Appears as "USB Advanced Audio Device".
- Movo MC3 (TRS to TRRS into the MacBook headphone jack), in use since 2026-09-15: appears as "External Microphone", 48 kHz; the mic and markers work, and the level landed in the target window at the jack's 21% input gain with no correction. macOS may route output to the jack too; reselect the speakers if so. Selecting a device in the menu's "Input device" picker starts listening on it.

## 2026-09-15: stale recognizer sessions

After the app sat idle overnight, every message came back empty: the recognizer sessions pre-built for the next
message had gone stale. Sessions older than 120 s are now replaced at the start of a squeeze (audio is buffered
meanwhile), and they are dropped on hang-up. Recognizer diagnostics are logged. Also logged: the source of every
hang-up (click, hotkey, menu item, double tap, idle timer, quit), after three unexplained hang-ups a second after
pick-up on 2026-09-13. Toggle is debounced at 600 ms.

## 2026-09-15 evening

- Shake to cancel loosened to 0.4 g, three alternating swings within 550 ms (Miguel: too hard at 0.5 g / four).
- Menu trimmed to: Start/Stop listening, Shake to cancel (toggle, on), Input device, Launch at login, Quit, plus
  "Grant Accessibility access…" only while not granted. No HUD on hang-up.

- 2026-09-15 20:33: a 44 s message was cut by the 90 s utterance cap. Cap removed; the idle timer skips while a message is open. A message ends only on release or a shake.

## Target sessions (2026-09-15 evening)

The desktop app keeps one JSON per Code session under `~/Library/Application Support/Claude/claude-code-sessions/`
(`sessionId` = `local_…`, `title`, `lastFocusedAt`, `isArchived`); those ids differ from the CLI session uuids in
`~/.claude/projects`. The Target menu lists the five most recently focused and shows the effective target by name: an explicit pick, otherwise the last focused. Timestamps are epoch milliseconds. A sidebar switch updates `lastFocusedAt`, so after a targeted message that session is the last used and the explicit pick clears (Miguel's spec, 2026-09-15 23:10). Switching is done through the sidebar:
each session is an `AXButton` titled "Idle <title>" or "Running <title>"; AXPress on it changes the view without
activating the app, and the active session can be read from the header button described "<title>, rename session".
`claude://code/continue?session=<local id>` also exists but activates the window. Verified: a message sent to
"mic test session" while another session was on screen landed there, and the next one came back to the original.

- 2026-09-15 23:25 to 23:40: HUD is one toast that slides down from the top edge on squeeze (180 ms) and back up when done (150 ms), relabels in place without text animation (Listening, Sending… with an up arrow, Sent, Canceled); meter pushed every 10 ms hop with instant attack and ~150 dB/s release, 30 ms bar animation.

- 2026-09-15 23:50 to 2026-09-16 00:06: session activity is read from the target session's sidebar label ("Running <title>" / "Idle <title>", polled through Accessibility by `ActivityWatcher`). Two notification toasts were tried and removed at Miguel's request; progress shows on the menu bar icon instead: three pulsing dots badge the handset's upper-right corner while the session runs, then a check for two seconds, drawn inside the same 18-point icon with a knocked-out outline.

## 2026-09-19: audio path recovery

Miguel switched the sound output from the headphone jack to the speakers while listening; the orange mic dot went
away but the app still showed itself armed. Cause: the output switch reconfigures the jack's audio hardware and
AVAudioEngine stops itself (`AVAudioEngineConfigurationChange`); the app never noticed. Fix: the capture reports
engine stops, a 2 s heartbeat catches a capture that delivers no buffers or is not running, and a CoreAudio
device-list listener catches a vanished device. Recovery waits 0.4 s (2 s after three interruptions in ten seconds), then: device gone
from the system, hang up at once (Miguel: a disconnected input must hang up); device present, restart the same
engine, or rebuild the capture on it once, or hang up. Hang-ups stay silent; the handset icon shows the state.
- Second finding, same day: restarting the stopped engine was not enough. After the switch the engine came back bound to
  `CADefaultDeviceAggregate-…`, macOS's default-input aggregate (the built-in mic), so audio flowed and the dot came
  back while the marker tones from the jack were never heard. Recovery now always rebuilds the capture on our device,
  `InputCapture.start()` verifies the bound device and throws if it is wrong, and the 1 s heartbeat checks the bound
  device too ("engine drifted to …" in the log). Verified with the output switcher: drift caught and rebuilt within
  about a second, twice. Notifications within 1 s of a start are ignored: the app's own setup (device binding, buffer
size) fires one, which had produced a reconnect loop at 5 Hz in the first attempt. Verified by switching the default
output twice with a CoreAudio tool: one interruption and one restart per switch, no loop.

## 2026-11-27: Claude's own dictation

Dictating in the Claude app through the same FX mic came out word for word, while FXMic's transcripts of the same
kind of audio had errors. Root cause: two different recognizers. The Claude app streams the mic
(`getUserMedia`, noise suppression on, default input, which here is the AB13X dongle carrying the FX mic) over a
websocket to Anthropic's server speech-to-text, with a key-terms vocabulary header. FXMic used Apple's on-device
`SpeechTranscriber`. Measured on one sentence recorded through the FX chain and the Mac's own mic at the same time,
both run through Apple's recognizer:

| audio into Apple's recognizer | confidence | result |
| --- | --- | --- |
| Mac mic | 0.87 | correct |
| Mac mic, low-passed at 7 kHz (the dongle) | 0.86 | correct |
| Mac mic, 40 dB down and back up (FX level) | 0.88 | correct |
| Mac mic, hard-gated between sounds (the mic's digital silence) | 0.80 | small errors |
| FX chain | 0.54 | "test of the attack, Mike", "ground clock… lazy dot" |

Band limit and level are not the problem; the gating hurts a little; Apple's model does not cope with the FX
signal as a whole, the server model does. No gain, gate or vocabulary setting gets Apple to parity, and the Claude
app's endpoint is internal to the app and its sign-in, so the fix is to let Claude transcribe.

`ClaudeDictation` (setting `transcriptionEngine` = `claude`): on the press marker it presses the composer's
`AXCheckBox` "Press and hold to record" (a single AXPress starts dictation; the label turns to "Stop dictation"), on
the release marker it presses it again, waits for the label to come back and the composer text to hold still
(0.7 to 0.9 s after release in tests), restores any draft the composer held, and hands the text to the existing
send/queue/draft delivery, addressed to the session it was dictated in. The control is not an `AXButton` and has no
"dictat" in its label, so the first probe missed it; `~/.fxmic/axdump` lists every control near each composer with
its DOM id and classes. Apple's recognizer still runs alongside as the fallback, and every message logs both. First
tests: "Recording is working. Saving as a draft." identical in both; "Using the draft right now…" from Claude,
"Squeezing the draft. Right now…" from Apple; "Hello, this is me testing again." sent end to end at 00:32.

Same day, second pass: the first version took the text back out of the composer and typed it in again through the
usual delivery, a visible clear-and-retype of identical text. Now the text stays where Claude put it: white leaves
it as the draft, a plain squeeze presses Send (queues if the session is busy and shows Stop), orange queues in
Claude with Cmd+Return posted to the Claude process (it works with Claude in the background; the composer
emptying is the check, and on failure the composer is restored and FXMic's own queue takes the text). Test: a white
squeeze kept "Testing one, testing two, testing three. All good." (Apple, alongside: "You? 1st one, destiny two,
destiny three. Oh, good.", 0.33), a second orange squeeze appended to it and Cmd+Return queued the whole composer.

FXMic is now signed with the local "FXMic Dev" identity, so rebuilds keep the Microphone and Accessibility grants.

## 2026-11-27: input closed between squeezes (USB reports)

The marker tones are the only way the Mac sees a squeeze, so the input had to stay open whenever FXMic was armed and
macOS showed the orange dot the whole time. With the mic on a USB-C data cable its CDC console is there anyway, so the
script now also prints one line per event (`report()` in `tools/build_fxmic_script.py`: press, release, queue, draft,
cancel, tap for the play button with the handle released, and `hi` every 120 ticks). `MicSerial` (FXMicCore) watches
`/dev/cu.usbmodemEP*` once a second, opens it read-only with the same raw/clocal setup as `tools/mp_exec.py` (no
writes, no modem-line changes, TIOCEXCL so a second reader gets EBUSY), and counts the port live while `fxmic` lines
keep coming (5 s timeout). Anything else on the console is ignored and never logged.

While live, tone markers are only logged; USB events drive the same squeeze code (`squeezeStarted`, `squeezeEnded`,
`shakeCancel`, intents), on one pipeline queue shared with the audio hops. The input opens at a squeeze only when
Apple's recognizer needs it (Apple mode, or Claude mode with `appleFallback`) and closes at the release. Claude's
dictation has its own input, so Claude mode with the fallback off never opens FXMic's input. Without audio the
squeeze's length stands in for the speech length in the drop rule.

Tested 2026-11-27 against a pseudo-terminal standing in for the mic (`usbPort` setting, test only): input closed while
armed; opened 72-109 ms after a press (2254 ms the first time, the dongle waking) and closed 12-16 ms after the
release; reports stopping mid-squeeze switched to tones within 5 s with the squeeze kept, and their return closed
the input after the release; cancel and REPL noise behaved. A first build reset `handleMode` when the input opened
mid-squeeze, so the release was ignored; fixed (`startCapture(midSqueeze:)`). TIOCEXCL does not apply to ptys.

With the mic, same day (script rebuilt from the device, firmware 1.1.2, cable left in): `fxmic hi` every 1.95 s;
`tools/mp_exec.py` gets "busy" while FXMic runs (TIOCEXCL works on the real port). Opening the port did not reset
the mic. Claude mode with the fallback: input opened 129-182 ms after the press, closed 19-50 ms after the release;
draft and queue intents arrived over USB. With `appleFallback` off, a per-process CoreAudio poll
(kAudioProcessPropertyIsRunningInput, every 0.2 s) showed only Claude Helper holding an input, from Claude's
dictation start to 8 ms after its stop, and nothing between squeezes. The orange dot that stayed on was another app
(a DAW) with its own input open. In that mode the Listening bar's meter had nothing to show and looked broken next to
Claude's live text, so FXMic now opens its input for the squeeze in every mode, only for the meter when the fallback
is off (Claude's dictation has the mic open then anyway, so the open time does not grow). The meter is hidden only if
the input fails to open. The Canceled bar shows no meter.

## 2026-11-27: a missed release kept Claude dictating

On the tones (cable out), a shake-cancel at 12:00:23, release at 25.2, and a new squeeze 0.9 s later at 26.1. No
release tone was ever heard for that squeeze, so FXMic stayed in it: Claude's dictation recorded from 28.9 until it
stopped on its own at 12:02:12, the Listening bar had been hidden by the canceled squeeze's late result at 27.5, and
the next release would have pressed the dictation control again (starting it, since Claude had stopped). Why the
release tone went unheard is not known (no tone of any kind was logged after 26.1). Fixes:

- A squeeze with no speech for 30 s and no release heard ends as a draft (`stuckSqueezeSeconds`). Nothing is sent
  that was not released. Tested with a fake mic and a 5 s limit.
- The release press only presses the dictation control, and only while it is listening (not its idle label).
- Results of an earlier squeeze no longer touch the Listening bar of the one in progress (`activeSqueeze`).
- Cancel is per squeeze (`canceledSerials`); before, a quick next squeeze reset the flag, so a canceled message with
  text could have been sent.
- A new dictation waits (up to 3 s) until the last squeeze's text in the composer has been sent, queued, kept or
  removed, so two messages never mix; an empty Claude result clears its pending completion.

None of this needs USB: every feature works on the audio adapter's tones; USB only adds the closed input.

## Open items

- Claude dictation: start takes 0.4 to 1 s after the squeeze; words before "Listening" can be lost. The plain-send
  path of the second pass (press Send in place) is not tested yet, nor dictation with the Claude window hidden.
- `SessionStore.lastUsed()` can return a "btw" side chat that is not in the sidebar, so Apple-mode delivery fails
  with "target session not in the sidebar".

- Load `packs/claude-pack/` on the mic (needs the USB-C cable for a minute).
- Gesture check still pending: single tap toggle after the activation fix. "Stop" was dropped on 2026-09-13 (Miguel: "stop what"); double tap now sleeps the app.
- Indicator: armed-and-idle model in place. USB wake is out because Miguel will not run a USB cable to the mic during use. The MicroPython serial console (`tools/repl.py`, `tools/serial_probe.py`) stays a setup and diagnostics tool.
- Level management: voice peaks near 0 dBFS at the current knob position; either turn the knob down a third or let the app set the Sabrent input gain.
