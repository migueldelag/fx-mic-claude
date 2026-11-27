import AppKit
import AVFoundation
import FXMicCore
import SwiftUI

/// Owns the audio pipeline, the transcriber, and the dispatch decisions.
/// Audio state is touched only on the capture queue; UI work is hopped to main.
final class AppController {
    enum State: String { case idle = "Idle", armed = "Armed", listening = "Listening" }

    private(set) var state: State = .idle {
        didSet { DispatchQueue.main.async { self.onStateChange?(); self.snapshot() } }
    }

    func snapshot() {
        Log.state([
            "state": state.rawValue,
            "device": deviceName ?? "",
            "transcriberReady": transcriberReady,
            "target": dispatcher.currentTarget?.title ?? "",
            "targetID": dispatcher.currentTarget?.id ?? "",
            "lastError": lastError ?? "",
            "micPermission": AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
            "handleMode": handleMode,
            "composerDelivery": settings.composerDelivery,
            "shakeToCancel": settings.shakeToCancel,
            "captureRunning": capture?.isRunning ?? false,
            "trigger": usbLiveMain ? "usb" : "tones",
            "appleFallback": settings.appleFallback,
            "accessibilityTrusted": ComposerDelivery.isTrusted,
        ])
    }
    var onStateChange: (() -> Void)?
    var onActivity: ((StatusMenu.Activity) -> Void)?
    var onRecentChange: (() -> Void)?

    let settings = Settings.shared
    let hud = HUDController()
    let dispatcher = Dispatcher()
    private let activity = ActivityWatcher()
    /// Claude's own dictation, used when settings.transcriptionEngine is "claude".
    let dictation = ClaudeDictation()
    /// The squeeze in progress is being dictated in Claude (capture queue).
    private var claudeSqueeze = false
    /// Claude is listening for the squeeze in progress, so its composer text drives the Listening bar (main).
    private var claudeLive = false
    /// The session each Claude-dictated squeeze was spoken into; its text is delivered there (main).
    private var dictatedSession: [Int: String] = [:]
    private(set) var recent: [(date: Date, text: String, outcome: String)] = []
    private(set) var lastError: String?
    var deviceName: String? { capture?.device.name }
    var transcriberReady: Bool { transcriber != nil }

    /// Squeeze reports from the mic's USB serial console. While they arrive, the input is closed between squeezes.
    let usb = MicSerial(match: Settings.shared.usbPort)
    /// The pipeline queue: audio hops from every capture and the USB events run here, one at a time.
    private let pipeline = DispatchQueue(label: "fxmic.pipeline")
    /// The mic is reporting squeezes over USB: tone markers are ignored (pipeline copy).
    private var usbLive = false
    /// The same, for main-thread decisions (opening and closing the input, the menu).
    private(set) var usbLiveMain = false
    private var squeezeStartedAt = Date.distantPast       // pipeline
    private var pendingTap: DispatchWorkItem?             // main

    // Pipeline state, pipeline queue only.
    private var capture: InputCapture?
    private var gate = SpeechGate()
    private var chirps: ChirpDetector?
    private var handleMode = false          // true while an utterance was opened by a press marker: only the release marker ends it
    private var sampleRate: Double = 48000
    private var hopSeconds = 0.010
    private var preroll: [[Float]] = []
    private var speechFrames = 0
    private var openFrames = 0
    private var utterancePeak: Float = -160
    private var chirpDuringUtterance = false
    private var lastSpeechChirp = Date.distantPast
    private var canceled = false                     // the squeeze in progress was canceled: no meter (pipeline)
    /// Squeezes canceled with a shake; their text is never delivered (main).
    private var canceledSerials = Set<Int>()
    /// The squeeze in progress, if any: results of earlier squeezes do not touch its Listening bar (main).
    private var activeSqueeze: Int?
    private var lastSpeechAt = Date.distantPast        // pipeline
    private var utteranceSerial = 0
    private var lastLevelPush = Date.distantPast
    private var meterLevel: Float = -60
    private var partials: [String: String] = [:]
    /// Latest live transcript per recognizer locale for the squeeze in progress (main).
    private var livePartials: [String: (text: String, confidence: Double)] = [:]
    private var transcriberGain: Float = 1          // linear, from settings.transcriberGainDb at each capture start
    /// Pressing orange during a squeeze makes the mic repeat the press tone (queue: send when Claude finishes its
    /// turn); white plays the tap tone (draft: leave in the composer). The Listening bar shows the mode.
    enum Intent: String { case send, queue, draft }
    private var intents: [Int: Intent] = [:]             // main
    private var queued: [(text: String, target: String, at: Date)] = []   // main
    private var queueTimer: Timer?
    private var lastQueuedSendAt = Date.distantPast
    /// Debug hook: FXMIC_RECORD=/path.wav saves everything the live input delivers, until FXMic stops listening.
    private var debugRecorder: WavWriter?
    /// Debug hook: while FXMIC_REPLAY feeds a recording, live input is ignored.
    private var replayActive = false

    private let transcriberLock = NSLock()
    private var _transcriber: LiveTranscriber?
    private var transcriberStarting = false
    private var transcriber: LiveTranscriber? {
        transcriberLock.lock(); defer { transcriberLock.unlock() }
        return _transcriber
    }
    private func setTranscriber(_ t: LiveTranscriber?, starting: Bool) {
        transcriberLock.lock(); defer { transcriberLock.unlock() }
        if let t { _transcriber = t }
        transcriberStarting = starting
    }

    private var lastActivity = Date()
    private var idleTimer: Timer?
    private var pendingDeliveries = 0

    // MARK: arm / idle

    init() {
        startSendFileWatcher()
        usb.log = { Log.write($0) }
        usb.onLiveChange = { [weak self] live in
            guard let self else { return }
            self.pipeline.async {
                self.usbLive = live
                if live { self.preroll = [] }          // never feed a later squeeze audio from before it
                DispatchQueue.main.async { self.usbLiveChanged(live) }
            }
        }
        usb.onEvent = { [weak self] event in
            guard let self else { return }
            self.pipeline.async { self.usbEvent(event) }
        }
        if settings.usbTrigger { usb.start() }
        dictation.onPartial = { [weak self] text in
            guard let self, self.claudeLive, !text.isEmpty else { return }
            self.hud.partial(text)
        }
    }

    private var lastToggle = Date.distantPast

    /// Called by the menu bar click and the hotkey. Ignores a second toggle within 600 ms (double-clicks).
    func toggleArmed(source: String) {
        let now = Date()
        guard now.timeIntervalSince(lastToggle) > 0.6 else { Log.write("toggle from \(source) ignored (debounce)"); return }
        lastToggle = now
        Log.write("toggle from \(source): \(state == .idle ? "pick up" : "hang up")")
        state == .idle ? arm() : disarm(reason: "hung up via \(source)")
    }

    func arm() {
        guard state == .idle else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            Log.write("waiting for microphone permission")
            snapshot()
            hud.flash("Microphone permission", detail: "Click Allow in the macOS dialog, then FXMic starts listening.", tint: .blue, icon: "mic.badge.plus", seconds: 6)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted { self.arm() } else { self.lastError = "Microphone access denied"; self.onStateChange?() }
                }
            }
            return
        case .denied, .restricted:
            lastError = "Microphone access denied. Allow FXMic in System Settings > Privacy & Security > Microphone."
            Log.write(lastError!)
            snapshot()
            hud.flash("Microphone access denied", detail: "System Settings > Privacy & Security > Microphone > FXMic", tint: .red, icon: "mic.slash", seconds: 4)
            onStateChange?()
            return
        default:
            break
        }
        guard let device = AudioDevices.find(settings.deviceQuery) else {
            lastError = "No input device matching \(settings.deviceQuery)"
            Log.write("no input device matching \(settings.deviceQuery)")
            hud.flash("Mic not found", detail: settings.deviceQuery, tint: .red, icon: "exclamationmark.triangle", seconds: 2.5)
            onStateChange?()
            return
        }
        do {
            if usbLiveMain {
                Log.write("armed on \(device.name); squeezes come over USB, the input stays closed until one")
            } else {
                try startCapture(device: device)
                Log.write("armed on \(device.name) at \(Int(sampleRate)) Hz")
            }
            lastError = nil
            lastActivity = Date()
            state = .armed
            ensureTranscriber()
            startIdleTimer()
            startHeartbeat()
            if settings.composerDelivery { ComposerDelivery.warmUp() }
            let env = ProcessInfo.processInfo.environment
            if let path = env["FXMIC_RECORD"], debugRecorder == nil {
                debugRecorder = try? WavWriter(url: URL(fileURLWithPath: path), sampleRate: Int(sampleRate))
                Log.write("debug: recording live input to \(path)")
            }
            if let path = env["FXMIC_REPLAY"] { replay(path) }
        } catch {
            lastError = "\(error)"
            Log.write("audio error: \(error)")
            hud.flash("Audio error", detail: "\(error)", tint: .red, icon: "exclamationmark.triangle", seconds: 3)
            onStateChange?()
        }
    }

    private func makeGate() -> SpeechGate {
        var config = GateConfig()
        config.openDb = settings.openDb
        config.closeDb = settings.closeDb
        config.openFrames = 5        // 50 ms of sustained energy starts a message; bumps and chirps do not count
        config.holdFrames = 60
        return SpeechGate(config: config)
    }

    /// Opens the input and builds the detectors for it. Used by arm(), by recovery, and (`midSqueeze`) when a squeeze
    /// reported over USB needs audio: the squeeze in progress and its gate are kept then.
    private func startCapture(device: AudioInputDevice, midSqueeze: Bool = false) throws {
        if !midSqueeze {
            gate = makeGate()
            preroll = []
        }
        let config = gate.config
        let cap = try InputCapture(device: device, queue: pipeline) { [weak self] frame in self?.process(frame) }
        sampleRate = cap.sampleRate
        hopSeconds = Double(cap.hop) / cap.sampleRate
        transcriberGain = powf(10, settings.transcriberGainDb / 20)
        var chirpConfig = ChirpConfig()
        chirpConfig.minLevelDb = settings.chirpMinLevelDb
        chirps = ChirpDetector(targets: [
            ToneTarget(name: "tap", freqs: settings.chirpFreqs),
            ToneTarget(name: "press", freqs: settings.pressFreqs),
            ToneTarget(name: "release", freqs: settings.releaseFreqs),
            ToneTarget(name: "cancel", freqs: settings.cancelFreqs),
        ], sampleRate: sampleRate, hopSeconds: hopSeconds, config: chirpConfig)
        Log.write(String(format: "tone threshold %.0f dB, speech threshold %.0f dB, transcriber gain %+.0f dB, locales %@",
                         chirpConfig.minLevelDb, config.openDb, settings.transcriberGainDb, settings.locales.joined(separator: ",")))
        Log.write("tones: " + (chirps?.targets.map { "\($0.name)=\($0.freqs.map { Int($0) })" }.joined(separator: " ") ?? "none"))
        if !midSqueeze { handleMode = false }
        cap.onStopped = { [weak self] reason in
            DispatchQueue.main.async { self?.recover(reason: reason) }
        }
        try cap.start()
        capture = cap
    }

    // MARK: recovery

    private var recovering = false
    private var heartbeat: Timer?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    /// The audio path died under us (jack reconfigured, device unplugged, engine stopped): reconnect, or hang up
    /// honestly if the device does not come back within a few seconds.
    private var lastRecoveryAt = Date.distantPast
    private var recoveriesInWindow = 0

    private func recover(reason: String) {
        guard state != .idle, !recovering else { return }
        recovering = true
        // Backoff: a storm of interruptions (jack reconfiguring) gets a longer pause instead of a tight loop.
        if Date().timeIntervalSince(lastRecoveryAt) < 10 { recoveriesInWindow += 1 } else { recoveriesInWindow = 0 }
        lastRecoveryAt = Date()
        let delay: TimeInterval = recoveriesInWindow >= 3 ? 2.0 : 0.4
        Log.write("capture interrupted: \(reason); recovering in \(delay) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.state != .idle else { self?.recovering = false; return }
            // Closed on purpose in the meantime (a USB-reported squeeze ended): nothing to recover.
            guard self.capture != nil else { self.recovering = false; return }
            // Device gone (adapter or mic unplugged): hang up at once. The half-second delay above filters blips.
            guard let cap = self.capture, AudioDevices.exists(cap.device.id) else {
                self.recovering = false
                self.disarm(reason: "input device disconnected (\(self.settings.deviceQuery))")
                return
            }
            // Device still there: rebuild the capture on it. (Restarting the stopped engine is not enough: it can come
            // back bound to the default input, the built-in mic, and never hear the marker tones again.)
            self.capture?.stop()
            self.capture = nil
            if let device = AudioDevices.find(self.settings.deviceQuery) {
                do {
                    try self.startCapture(device: device)
                    self.recovering = false
                    Log.write("reconnected to \(device.name) at \(Int(self.sampleRate)) Hz")
                    self.snapshot()
                    return
                } catch {
                    Log.write("rebuild failed: \(error)")
                }
            }
            self.recovering = false
            self.disarm(reason: "input device unusable (\(self.settings.deviceQuery))")
        }
    }

    /// Every second: a capture that delivers no buffers, is not running, or is bound to another device is dead.
    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.state != .idle else { return }
            self.checkMicMode()
            guard !self.recovering, let cap = self.capture else { return }
            if !cap.isRunning { self.recover(reason: "engine not running") }
            else if Date().timeIntervalSince(cap.lastHopAt) > 3 { self.recover(reason: "no audio for 3 s") }
            else if let bound = cap.boundDeviceID(), bound != cap.device.id {
                let name = AudioDevices.inputs().first { $0.id == bound }?.name ?? "\(bound)"
                self.recover(reason: "engine drifted to \(name)")
            }
        }
        if deviceListener == nil {
            deviceListener = AudioDevices.onDeviceListChange { [weak self] in
                guard let self, self.state != .idle, !self.recovering, let cap = self.capture else { return }
                if !AudioDevices.exists(cap.device.id) { self.recover(reason: "input device disappeared") }
            }
        }
    }

    /// macOS applies the Control Center Mic Mode per app. Voice Isolation passes speech but silences the marker tones
    /// within a few milliseconds, so squeezes are never seen and nothing reports an error. Warn when it is active.
    private var lastMicMode: AVCaptureDevice.MicrophoneMode?
    private func checkMicMode() {
        let mode = AVCaptureDevice.activeMicrophoneMode
        guard mode != lastMicMode else { return }
        lastMicMode = mode
        let name: String
        switch mode {
        case .standard: name = "Standard"
        case .wideSpectrum: name = "Wide Spectrum"
        case .voiceIsolation: name = "Voice Isolation"
        @unknown default: name = "mode \(mode.rawValue)"
        }
        Log.write("mic mode: \(name)")
        if mode == .voiceIsolation {
            lastError = "Mic Mode is Voice Isolation: it removes the squeeze tones. Choose Standard in Control Center > Mic Mode."
            hud.flash("Voice Isolation is on", detail: "It removes the squeeze tones. Choose Standard.", tint: .red, icon: "waveform.slash", seconds: 6)
            AVCaptureDevice.showSystemUserInterface(.microphoneModes)
            onStateChange?()
        }
    }

    func disarm(reason: String? = nil) {
        guard state != .idle else { return }
        idleTimer?.invalidate()
        idleTimer = nil
        heartbeat?.invalidate()
        heartbeat = nil
        recovering = false
        capture?.stop()
        capture = nil
        if let recorder = debugRecorder { debugRecorder = nil; recorder.close() }
        if claudeSqueeze { claudeSqueeze = false; dictation.abort() }
        Log.write("idle" + (reason.map { ": \($0)" } ?? ""))
        state = .idle
        hud.hide()      // hanging up is silent: the menu bar handset shows the state
    }

    /// Keeps speech peaks between -20 and -4 dBFS by nudging the Sabrent's own input gain.
    private func autoTrim(peakDb: Float) {
        guard settings.autoGain, let device = capture?.device, let current = AudioDevices.inputVolume(device.id) else { return }
        var next = current
        if peakDb > -2 { next = current * 0.7 }
        else if peakDb > -4 { next = current * 0.85 }
        else if peakDb < -24 { next = min(1, current * 1.2 + 0.02) }
        guard abs(next - current) > 0.005 else { return }
        if AudioDevices.setInputVolume(device.id, next) {
            Log.write(String(format: "auto gain: peak %.1f dBFS, input gain %.0f%% -> %.0f%%", peakDb, current * 100, next * 100))
        }
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.state != .idle else { return }
            let limit = self.settings.idleMinutes * 60
            if limit > 0, self.state != .listening, !self.handleMode, Date().timeIntervalSince(self.lastActivity) > limit {   // never mid-message
                self.disarm(reason: "Idle after \(Int(self.settings.idleMinutes)) min")
            }
        }
    }

    private func ensureTranscriber() {
        transcriberLock.lock()
        let needed = _transcriber == nil && !transcriberStarting
        if needed { transcriberStarting = true }
        transcriberLock.unlock()
        guard needed else { return }
        let locales = settings.locales
        LiveTranscriber.fastResults = settings.fastLiveText
        LiveTranscriber.previewLane = settings.livePreview && settings.hudTranscript
        Task.detached { [self] in
            do {
                let t = try await LiveTranscriber(locales: locales) { [weak self] update in self?.handle(update) }
                setTranscriber(t, starting: false)
                Log.write("transcriber ready: \(locales.joined(separator: ","))")
                DispatchQueue.main.async { self.onStateChange?(); self.snapshot() }
            } catch {
                setTranscriber(nil, starting: false)
                Log.write("transcriber failed: \(error)")
                DispatchQueue.main.async {
                    self.lastError = "Transcriber: \(error)"
                    self.hud.flash("Transcriber failed", detail: "\(error)", tint: .red, icon: "exclamationmark.triangle", seconds: 3)
                    self.onStateChange?()
                }
            }
        }
    }

    // MARK: audio pipeline (capture queue)

    private func process(_ frame: [Float], replayed: Bool = false) {
        if replayActive && !replayed { return }
        if !replayed { debugRecorder?.append(frame) }
        preroll.append(frame)
        if preroll.count > 20 { preroll.removeFirst() }

        let chirpEvents = chirps?.process(frame) ?? []
        let toneActive = chirps?.toneActive ?? false
        let rms = Levels.rmsDb(frame)

        // Every tone onset with its level and SNR, so a missing squeeze can be told apart from a missing tone.
        for event in chirpEvents {
            if case .onset(let target, let level, let snr) = event {
                Log.write(String(format: "tone %@ level %.1f dB snr %.0f dB", target, level, snr))
            }
        }

        // Handle markers from the mic's script: press opens the message, release sends it. While the mic reports
        // squeezes over USB, the same events come from there and the tones are only logged.
        for event in chirpEvents where !usbLive {
            guard case .onset(let target, _, _) = event else { continue }
            if target == "press", handleMode {
                setIntent(.queue)                     // a second press tone inside a squeeze: orange pressed
            } else if target == "tap", handleMode {
                setIntent(.draft)                     // the play tone inside a squeeze: white pressed
            } else if target == "press" {
                squeezeStarted()
            } else if target == "cancel", handleMode {
                shakeCancel()
            } else if target == "release", handleMode {
                squeezeEnded()
            }
        }

        // The gate only tracks speech energy inside a squeeze. Speech without a press marker is ignored:
        // the handle is the only thing that starts or ends a message.
        for event in gate.process(rmsDb: toneActive ? -100 : rms) {
            if case .closed = event, handleMode { gate.forceOpenSilently() }
        }
        if !handleMode, gate.isOpen { gate.forceClose() }

        if handleMode, gate.isOpen {
            openFrames += 1
            if !toneActive, rms > gate.config.openDb {
                speechFrames += 1
                lastSpeechAt = Date()
                utterancePeak = max(utterancePeak, Levels.peakDb(frame))
            }
            feedTranscriber(frame)
            // No time cap: a message ends only on the release marker or a shake.
            // Meter ballistics: instant attack, about 150 dB/s release, pushed to the HUD on every 10 ms hop.
            meterLevel = max(rms, meterLevel - 1.5)
            if !canceled, Date().timeIntervalSince(lastLevelPush) > 0.009 {   // a canceled squeeze shows no level
                lastLevelPush = Date()
                let shown = meterLevel
                DispatchQueue.main.async { self.hud.model.level = shown }
            }
        }

        // A release that was never heard (a missed tone) would keep the squeeze, and Claude's dictation, open for good.
        // After this long without speech the squeeze ends as a draft: nothing is sent that was not released.
        let limit = settings.stuckSqueezeSeconds
        if handleMode, limit > 0, Date().timeIntervalSince(max(lastSpeechAt, squeezeStartedAt)) > limit {
            Log.write(String(format: "no speech for %.0f s and no release heard: ending the squeeze as a draft", limit))
            setIntent(.draft)
            squeezeEnded()
        }

        for event in chirpEvents where !usbLive {
            switch event {
            case .onset(let target, _, _):
                // A tap while the handle is squeezed is always a cancel, spoken or not; never an app switch.
                if target == "tap", handleMode || gate.isOpen {
                    chirpDuringUtterance = true
                    lastSpeechChirp = Date()
                }
            case .hold:
                Log.write("long tone (ignored)")
            case .tap(let target, let count):
                guard target == "tap" else { break }
                // A tap resolves up to 450 ms after its chirp; only a chirp that landed inside speech within the last second counts.
                let duringSpeech = Date().timeIntervalSince(lastSpeechChirp) < 1.0
                DispatchQueue.main.async { self.tapAction(count: count, duringSpeech: duringSpeech) }
            case .release:
                break
            }
        }
    }

    /// Feeds the recognizer, with the transcriber-only gain (clipped). The level meter, gate and markers use the
    /// unamplified signal.
    private func feedTranscriber(_ frame: [Float]) {
        guard appleWanted, let t = transcriber else { return }      // fallback off: the audio only drives the meter
        if transcriberGain == 1 { t.feed(frame, sampleRate: sampleRate); return }
        t.feed(frame.map { max(-1, min(1, $0 * transcriberGain)) }, sampleRate: sampleRate)
    }

    private func beginUtterance() {
        utteranceSerial += 1
        speechFrames = 0
        openFrames = 0
        utterancePeak = -160
        chirpDuringUtterance = false
        canceled = false
        partials = [:]
        lastActivity = Date()
        if appleWanted { transcriber?.startUtterance() }
        for f in preroll.dropLast() { feedTranscriber(f) }
        state = .listening
        activity.cancel()
        DispatchQueue.main.async { self.onActivity?(.none) }
        let serial = utteranceSerial
        DispatchQueue.main.async { self.activeSqueeze = serial; self.livePartials = [:]; self.showListeningIfNeeded() }
    }

    private var hudShownForSerial = -1
    /// Where Apple-mode text will go: the session picked in the menu, else the last used one, else the inbox target.
    private var expectedTarget: String? {
        if settings.composerDelivery, ComposerDelivery.isTrusted,
           let title = settings.targetSessionTitle ?? SessionStore.lastUsed()?.title { return title }
        return dispatcher.currentTarget?.title ?? "No session armed: will copy to the clipboard"
    }

    private func showListeningIfNeeded() {
        guard state == .listening, hudShownForSerial != utteranceSerial else { return }
        hudShownForSerial = utteranceSerial
        if settings.transcriptionEngine == "claude" {
            // The conversation is known once Claude's dictation starts in it; until then the bar is grey.
            hud.listening(target: nil)
            hud.starting()
        } else {
            hud.listening(target: expectedTarget)
        }
    }

    private func endUtterance(frames: Int) {
        handleMode = false
        // No audio reached FXMic (squeezes over USB, Claude's dictation only): the squeeze's length stands in.
        let speechSeconds = openFrames > 0 ? Double(speechFrames) * hopSeconds : Date().timeIntervalSince(squeezeStartedAt)
        let serial = utteranceSerial
        let hadChirp = chirpDuringUtterance
        if speechSeconds >= 0.5 { autoTrim(peakDb: utterancePeak) }
        state = .armed
        let viaClaude = claudeSqueeze
        claudeSqueeze = false
        let t = appleWanted ? transcriber : nil
        guard t != nil || viaClaude else {
            DispatchQueue.main.async { self.hud.flash("Transcriber not ready yet", tint: .yellow, icon: "hourglass") }
            return
        }
        let hadSpeech = speechSeconds >= 0.3
        DispatchQueue.main.async {
            self.pendingDeliveries += 1
            if self.activeSqueeze == serial { self.activeSqueeze = nil }
            if self.canceledSerials.contains(serial) { return }
            let label: String
            switch self.intents[serial] ?? .send {
            case .draft: label = "Adding to draft…"
            case .queue: label = "Queueing…"
            case .send: label = "Sending…"
            }
            if hadSpeech { self.hud.sending(label) } else { self.hud.hide(after: 0.15) }
        }
        Task.detached { [self] in
            // Claude's dictation and Apple's recognizer finish side by side; Claude's text wins, Apple's is the fallback.
            async let claude = viaClaude ? self.finishClaudeDictation(serial: serial) : nil
            let apple = await t?.finishUtterance() ?? UtteranceResult(text: "", locale: "", confidence: 0, alternatives: [])
            let result = self.pick(apple: apple, claude: await claude, serial: serial)
            // A tap during speech resolves up to 450 ms after the release; give it time to cancel.
            let delay: TimeInterval = hadChirp ? 0.6 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.pendingDeliveries -= 1
                self.deliver(result, speechSeconds: speechSeconds, serial: serial)
            }
        }
    }

    /// Recognizer updates arrive per locale lane on the transcriber's tasks. The Listening bar shows the lane that is
    /// more confident right now (the longer text on a tie), so an English sentence is not shown as its Spanish guess.
    private func handle(_ update: TranscriptUpdate) {
        if update.text.hasPrefix("[") { Log.write("recognizer \(update.locale): \(update.text)"); return }
        if claudeLive { return }                                // Claude's own text is in the bar
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if update.locale.hasSuffix("+preview") {               // the fast preview lane drives the bar on its own
            DispatchQueue.main.async { self.hud.partial(text) }
            return
        }
        if LiveTranscriber.previewLane { return }
        DispatchQueue.main.async {
            self.livePartials[update.locale] = (text, update.confidence)
            let best = self.livePartials.values.max { a, b in
                abs(a.confidence - b.confidence) > 0.02 ? a.confidence < b.confidence : a.text.count < b.text.count
            }
            if let best { self.hud.partial(best.text) }
        }
    }

    // MARK: squeezes (pipeline queue), from the tones or from USB

    /// Apple's recognizer transcribes this squeeze: always in Apple mode, and as the fallback in Claude mode.
    private var appleWanted: Bool { settings.transcriptionEngine != "claude" || settings.appleFallback }

    private func squeezeStarted() {
        lastActivity = Date()
        squeezeStartedAt = Date()
        lastSpeechAt = .distantPast
        if usbLive { preroll = []; gate = makeGate() }
        if !gate.isOpen { beginUtterance() }
        handleMode = true
        gate.forceOpenSilently()
        Log.write("handle pressed" + (usbLive ? " (usb)" : ""))
        if settings.transcriptionEngine == "claude" { startClaudeDictation() }
        // Over USB the input is closed until now; it opens for the squeeze only. It drives the level meter, and Apple's
        // recognizer when wanted. Claude's dictation has the mic open for the squeeze anyway, so this adds no time.
        if usbLive { DispatchQueue.main.async { self.openInput(reason: "squeeze") } }
    }

    private func squeezeEnded() {
        Log.write("handle released" + (usbLive ? " (usb)" : ""))
        handleMode = false
        endUtterance(frames: openFrames)
        gate.forceClose()
        if usbLive { DispatchQueue.main.async { self.closeInputBetweenSqueezes() } }
    }

    private func shakeCancel() {
        guard settings.shakeToCancel else { return }
        Log.write("shake: cancel")
        let serial = utteranceSerial
        canceled = true
        DispatchQueue.main.async { self.canceledSerials.insert(serial); self.hud.canceled() }
    }

    private func usbEvent(_ event: MicSerial.Event) {
        guard usbLive, state != .idle, !replayActive else { return }
        switch event {
        case .hi: break
        case .press: if !handleMode { squeezeStarted() }
        case .release: if handleMode { squeezeEnded() }
        case .queue: if handleMode { setIntent(.queue) }
        case .draft: if handleMode { setIntent(.draft) }
        case .cancel: if handleMode { shakeCancel() }
        case .tap: if !handleMode { DispatchQueue.main.async { self.usbTap() } }
        }
    }

    // MARK: USB trigger (main)

    /// The menu switch: watch the mic's USB console, or ignore it and always use the tones.
    func setUSBTrigger(_ on: Bool) {
        Log.write("mic open only while squeezing: \(on ? "on" : "off")")
        if on { usb.start() } else { usb.stop() }       // stopping reports "not live", which reopens the input
        snapshot()
    }

    private func usbLiveChanged(_ live: Bool) {
        usbLiveMain = live
        Log.write(live ? "usb: the mic reports squeezes; the input stays closed between squeezes"
                       : "usb: no squeeze reports; listening for the marker tones")
        snapshot()
        guard state != .idle else { return }
        if live {
            closeInputBetweenSqueezes()
        } else if capture == nil {
            // Mid-squeeze too (cable pulled): the release tone ends it.
            openInput(reason: "listening for tones")
        }
    }

    /// Opens the input while armed, when it is not open yet.
    private func openInput(reason: String) {
        guard state != .idle, capture == nil, !recovering else { return }
        guard let device = AudioDevices.find(settings.deviceQuery) else {
            Log.write("no input device matching \(settings.deviceQuery)")
            hud.hideMeter()
            return
        }
        let t0 = Date()
        do {
            try startCapture(device: device, midSqueeze: pipeline.sync { handleMode })
            Log.write(String(format: "input opened (%@) in %.0f ms", reason, Date().timeIntervalSince(t0) * 1000))
        } catch {
            Log.write("input failed to open (\(reason)): \(error)")
            hud.hideMeter()                                     // no level to show for this squeeze
        }
        snapshot()
    }

    /// Closes the input when squeezes come over USB and none is in progress.
    private func closeInputBetweenSqueezes() {
        guard usbLiveMain, let cap = capture else { return }
        let squeezing = pipeline.sync { handleMode }
        guard !squeezing else { return }
        cap.stop()
        capture = nil
        Log.write("input closed")
        snapshot()
    }

    /// The mic reports each press of the play button; two within 450 ms are a double tap, like the tone detector.
    private func usbTap() {
        if let pending = pendingTap {
            pending.cancel()
            pendingTap = nil
            tapAction(count: 2, duringSpeech: false)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingTap = nil
            self?.tapAction(count: 1, duringSpeech: false)
        }
        pendingTap = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    // MARK: Claude dictation

    /// Presses Claude's dictation button for this squeeze. Capture queue.
    private func startClaudeDictation() {
        claudeSqueeze = true
        let serial = utteranceSerial
        let target = settings.targetSessionTitle ?? SessionStore.lastUsed()?.title
        DispatchQueue.main.async { self.hud.starting() }
        dictation.start(serial: serial, target: target) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let session):
                self.claudeLive = true
                if !session.isEmpty { self.dictatedSession[serial] = session }
                self.hud.listeningReady(session: session)
            case .failure(let error):
                Log.write("dictation: could not start (\(error)), Apple's recognizer takes this message")
                self.claudeLive = false
                self.hud.listeningReady(session: self.expectedTarget)
            }
        }
    }

    private func finishClaudeDictation(serial: Int) async -> Result<String, ClaudeDictation.Failure> {
        await withCheckedContinuation { continuation in
            dictation.finish(serial: serial) { continuation.resume(returning: $0) }
        }
    }

    /// Claude's text when it has any, otherwise Apple's. Both are logged so the two can be compared.
    private func pick(apple: UtteranceResult, claude: Result<String, ClaudeDictation.Failure>?, serial: Int) -> UtteranceResult {
        DispatchQueue.main.async { self.claudeLive = false }
        guard let claude else { return apple }
        let appleLine = String(format: "apple [%@ %.2f]: %@", apple.locale, apple.confidence, apple.text.isEmpty ? "(empty)" : apple.text)
        switch claude {
        case .success(let text) where !text.isEmpty:
            Log.write("compare: claude: \(text) | \(appleLine)")
            return UtteranceResult(text: text, locale: "claude", confidence: 1, alternatives: [])
        case .success:
            Log.write("compare: claude: (empty), using Apple's | \(appleLine)")
            dictation.complete(serial: serial, action: .discard) { _ in }    // nothing of Claude's to deliver
        case .failure(let error):
            Log.write("compare: claude failed (\(error)), using Apple's | \(appleLine)")
        }
        return apple
    }

    // MARK: delivery (main)

    private func deliver(_ result: UtteranceResult, speechSeconds: Double, serial: Int) {
        // Text dictated in Claude goes back to the session it was spoken into.
        let dictatedIn = dictatedSession.removeValue(forKey: serial)
        let inComposer = result.locale == "claude"      // Claude's dictation left this text in the composer
        if canceledSerials.remove(serial) != nil {
            Log.write("canceled: \(result.text)")
            if inComposer { dictation.complete(serial: serial, action: .discard) { _ in } }
            if activeSqueeze == nil { hud.hide(after: 0.3) }   // the shake already showed "Canceled"
            return
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 2, speechSeconds >= 0.4, result.confidence >= 0.35 else {
            Log.write(String(format: "dropped: %@ (%.1fs speech, conf %.2f)", text.isEmpty ? "empty" : text, speechSeconds, result.confidence))
            if inComposer { dictation.complete(serial: serial, action: .discard) { _ in } }
            if activeSqueeze == nil { hud.hide(after: 0.2) }
            return
        }
        let intent = intents.removeValue(forKey: serial) ?? .send
        if inComposer {
            deliverInComposer(text, intent: intent, session: dictatedIn, serial: serial, speechSeconds: speechSeconds)
            return
        }
        let outcome: String
        var hudTitle = "Sent"
        if settings.composerDelivery, ComposerDelivery.isTrusted, intent != .send,
           let target = dictatedIn ?? settings.targetSessionTitle ?? SessionStore.lastUsed()?.title {
            if intent == .draft {
                do {
                    try ComposerDelivery.send(text, toSessionTitled: target, pressSend: false)
                    outcome = "Draft in \(target)"
                } catch {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    outcome = "Draft failed (\(error)), copied"
                }
                hudTitle = "Draft"
            } else {
                queued.append((text, target, Date()))
                outcome = "Queued for \(target)"
                hudTitle = "Queued"
                startQueue()
            }
            if settings.targetSessionTitle != nil { settings.targetSessionTitle = nil }
        } else if settings.composerDelivery, ComposerDelivery.isTrusted {
            do {
                let target = dictatedIn ?? settings.targetSessionTitle ?? SessionStore.lastUsed()?.title
                try ComposerDelivery.send(text, toSessionTitled: target)
                outcome = target.map { "Sent to \($0)" } ?? "Sent to Claude"
                if settings.targetSessionTitle != nil { settings.targetSessionTitle = nil }   // it is the last used now
                if let target {
                    activity.watch(sessionTitle: target, onThinking: { [weak self] in
                        Log.write("activity: \(target) is thinking")
                        self?.onActivity?(.thinking)
                    }, onDone: { [weak self] in
                        Log.write("activity: \(target) done")
                        self?.onActivity?(.done)
                    })
                }
            } catch {
                Log.write("composer delivery failed (\(error)), using the inbox")
                outcome = inboxOutcome(text: text, result: result, speechSeconds: speechSeconds)
            }
        } else {
            outcome = inboxOutcome(text: text, result: result, speechSeconds: speechSeconds)
        }
        Log.write(String(format: "%@: %@  [%@ %.2f, %.1fs]", outcome, text, result.locale, result.confidence, speechSeconds))
        recent.insert((Date(), text, outcome), at: 0)
        if recent.count > 12 { recent.removeLast() }
        lastActivity = Date()
        if activeSqueeze == nil { hud.sent(text, outcome: outcome, title: hudTitle) }
        onRecentChange?()
    }

    /// Text Claude's dictation already put in the composer stays there: white leaves it as a draft, a plain squeeze
    /// presses Send, orange queues it in Claude (Cmd+Return). Nothing is cleared and typed again. If sending or
    /// queueing fails, the composer is put back as it was and the text goes to FXMic's own queue or the inbox.
    private func deliverInComposer(_ text: String, intent: Intent, session: String?, serial: Int, speechSeconds: Double) {
        let action: ClaudeDictation.Action = intent == .draft ? .keep : intent == .queue ? .queue : .send
        let target = session ?? settings.targetSessionTitle ?? SessionStore.lastUsed()?.title
        dictation.complete(serial: serial, action: action) { [weak self] result in
            guard let self else { return }
            let name = target ?? "Claude"
            var title = "Sent"
            let outcome: String
            switch result {
            case .success(.kept):
                outcome = "Draft in \(name)"; title = "Draft"
            case .success(.sent):
                outcome = "Sent to \(name)"
                if let target { self.watchActivity(target) }
            case .success(.queued):
                outcome = "Queued in Claude for \(name)"; title = "Queued"
                if let target { self.watchActivity(target) }
            case .success(.discarded):
                return
            case .failure(let error):
                if let target {
                    self.queued.append((text, target, Date()))
                    outcome = "Claude did not take it (\(error)), queued in FXMic for \(target)"; title = "Queued"
                    self.startQueue()
                } else {
                    outcome = self.inboxOutcome(text: text, result: UtteranceResult(text: text, locale: "claude", confidence: 1, alternatives: []), speechSeconds: speechSeconds)
                }
            }
            if self.settings.targetSessionTitle != nil { self.settings.targetSessionTitle = nil }
            Log.write(String(format: "%@: %@  [claude, %.1fs]", outcome, text, speechSeconds))
            self.recent.insert((Date(), text, outcome), at: 0)
            if self.recent.count > 12 { self.recent.removeLast() }
            self.lastActivity = Date()
            if self.activeSqueeze == nil { self.hud.sent(text, outcome: outcome, title: title) }
            self.onRecentChange?()
        }
    }

    private func watchActivity(_ target: String) {
        activity.watch(sessionTitle: target, onThinking: { [weak self] in
            Log.write("activity: \(target) is thinking")
            self?.onActivity?(.thinking)
        }, onDone: { [weak self] in
            Log.write("activity: \(target) done")
            self?.onActivity?(.done)
        })
    }

    /// Records the queue/draft choice for the squeeze in progress and shows it in the Listening bar. Capture queue.
    private func setIntent(_ intent: Intent) {
        let serial = utteranceSerial
        Log.write("during squeeze: \(intent == .queue ? "orange pressed: queue" : "white pressed: draft")")
        DispatchQueue.main.async {
            self.intents[serial] = intent
            self.hud.mode(intent == .queue ? "Queue" : "Draft")
        }
    }

    /// Sends queued messages one at a time, each once its session is no longer in a turn. After a send it waits
    /// 10 s, so the session file has time to show the new turn before the next item is considered. An item still
    /// waiting after 30 minutes is left in the composer as a draft instead.
    private func startQueue() {
        Log.write("queue: \(queued.count) waiting")
        guard queueTimer == nil else { return }
        queueTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.serviceQueue() }
        serviceQueue()
    }

    private func serviceQueue() {
        guard let item = queued.first else { queueTimer?.invalidate(); queueTimer = nil; return }
        guard Date().timeIntervalSince(lastQueuedSendAt) > 10 else { return }
        let expired = Date().timeIntervalSince(item.at) > 30 * 60
        if !expired, SessionStore.isRunning(title: item.target) == true { return }
        queued.removeFirst()
        lastQueuedSendAt = Date()
        do {
            try ComposerDelivery.send(item.text, toSessionTitled: item.target, pressSend: !expired)
            Log.write("queue: \(expired ? "waited 30 min, left as draft in" : "sent to") \(item.target): \(item.text)")
            if activeSqueeze == nil { hud.sent(item.text, outcome: "", title: expired ? "Queued item left as draft" : "Sent queued message") }
        } catch {
            Log.write("queue: send failed (\(error)), copied to the clipboard: \(item.text)")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.text, forType: .string)
        }
    }

    private func inboxOutcome(text: String, result: UtteranceResult, speechSeconds: Double) -> String {
        switch dispatcher.dispatch(text: text, locale: result.locale, confidence: result.confidence, seconds: speechSeconds) {
        case .sent(let target): return "Sent to \(target.title)"
        case .copied: return "Copied, no session armed"
        }
    }

    /// Sends text exactly as if it had been spoken. Used by the send.txt test hook and the menu.
    func deliverText(_ text: String) {
        deliver(UtteranceResult(text: text, locale: "manual", confidence: 1, alternatives: []), speechSeconds: 1, serial: -1)
    }

    /// ~/.fxmic/send.txt: drop a file there and its content is delivered like an utterance (debug and scripting hook).
    private func startSendFileWatcher() {
        let url = dispatcher.root.appendingPathComponent("send.txt")
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let dumpURL = self.dispatcher.root.appendingPathComponent("axdump")
            if FileManager.default.fileExists(atPath: dumpURL.path) {
                try? FileManager.default.removeItem(at: dumpURL)
                self.dictation.dump()
            }
            let demoURL = self.dispatcher.root.appendingPathComponent("huddemo")
            if FileManager.default.fileExists(atPath: demoURL.path) {
                try? FileManager.default.removeItem(at: demoURL)
                self.hudDemo()
            }
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(at: url)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { self.deliverText(trimmed) }
        }
    }

    /// Debug hook: FXMIC_REPLAY=/path/to.wav feeds a recording (48 kHz, for example one saved by fxmic-cal or
    /// FXMIC_RECORD) through the live pipeline 3 s after arming, at real-time pace, with live input muted meanwhile.
    /// Markers, transcription and delivery behave as if the audio came from the mic.
    private func replay(_ path: String) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else { Log.write("replay: cannot read \(path)"); return }
            let frames = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
            var mono = [Float](repeating: 0, count: frames)
            for c in 0..<channels { for i in 0..<frames { mono[i] += data[c][i] / Float(channels) } }
            let hop = self.capture?.hop ?? 480
            Log.write("replay: \(path) (\(frames) frames at \(Int(file.processingFormat.sampleRate)) Hz)")
            var i = 0
            while i + hop <= frames, let cap = self.capture {
                let chunk = Array(mono[i..<i + hop])
                cap.sync { self.replayActive = true; self.process(chunk, replayed: true) }
                i += hop
                Thread.sleep(forTimeInterval: Double(hop) / file.processingFormat.sampleRate)
            }
            self.capture?.sync { self.replayActive = false }
            Log.write("replay: done")
        }
    }

    /// Debug hook (`touch ~/.fxmic/huddemo`): plays the Listening bar's states with made-up text, a moving meter and
    /// nothing delivered, to check its layout and motion.
    private func hudDemo() {
        Log.write("debug: Listening bar demo")
        let words = "This is the Listening bar growing as words arrive, line after line, so its motion can be checked without sending anything."
            .split(separator: " ")
        hud.listening(target: nil)
        hud.starting()                                       // grey until "Claude" listens
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.hud.listeningReady(session: "Demo conversation") }
        for i in 0..<60 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(i) * 0.05) {
                self.hud.model.level = -40 + Float(sin(Double(i) / 3) * 18)
            }
        }
        for (i, _) in words.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4 + Double(i) * 0.18) {
                self.hud.partial(words[0...i].joined(separator: " "))
            }
        }
        let end = 1.4 + Double(words.count) * 0.18 + 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + end) { self.hud.sending() }
        DispatchQueue.main.asyncAfter(deadline: .now() + end + 0.6) {
            self.hud.sent(words.joined(separator: " "), outcome: "demo", title: "Sent")
        }
    }

    // MARK: button gestures (main)

    private func tapAction(count: Int, duringSpeech: Bool) {
        Log.write("tap x\(count)\(duringSpeech ? " while squeezed (ignored)" : "")")
        if duringSpeech { return }          // cancel is a shake now; the button does nothing while the handle is in
        lastActivity = Date()
        if count == 1 { ClaudeApp.toggle() } else { disarm(reason: "double tap") }
    }


    func newSession() {
        let folder = dispatcher.currentTarget?.cwd
        ClaudeApp.newCodeSession(folder: folder, prompt: "/fxmic")
        hud.flash("New Claude Code session", detail: folder ?? "Pick a folder in Claude", tint: .blue, icon: "plus.bubble", seconds: 2.5)
    }
}
