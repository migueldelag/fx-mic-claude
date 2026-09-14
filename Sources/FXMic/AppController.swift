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
            "accessibilityTrusted": ComposerDelivery.isTrusted,
        ])
    }
    var onStateChange: (() -> Void)?
    var onRecentChange: (() -> Void)?

    let settings = Settings.shared
    let hud = HUDController()
    let dispatcher = Dispatcher()
    private(set) var recent: [(date: Date, text: String, outcome: String)] = []
    private(set) var lastError: String?
    var deviceName: String? { capture?.device.name }
    var transcriberReady: Bool { transcriber != nil }

    // Pipeline state, capture queue only.
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
    private var canceled = false
    private var utteranceSerial = 0
    private var lastLevelPush = Date.distantPast
    private var partials: [String: String] = [:]

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
    }

    func toggleArmed() {
        state == .idle ? arm() : disarm()
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
        var config = GateConfig()
        config.openDb = settings.openDb
        config.closeDb = settings.closeDb
        config.openFrames = 5        // 50 ms of sustained energy starts a message; bumps and chirps do not count
        config.holdFrames = 60
        gate = SpeechGate(config: config)
        preroll = []
        do {
            let cap = try InputCapture(device: device) { [weak self] frame in self?.process(frame) }
            sampleRate = cap.sampleRate
            hopSeconds = Double(cap.hop) / cap.sampleRate
            chirps = ChirpDetector(targets: [
                ToneTarget(name: "tap", freqs: settings.chirpFreqs),
                ToneTarget(name: "press", freqs: settings.pressFreqs),
                ToneTarget(name: "release", freqs: settings.releaseFreqs),
                ToneTarget(name: "cancel", freqs: settings.cancelFreqs),
            ], sampleRate: sampleRate, hopSeconds: hopSeconds)
            handleMode = false
            try cap.start()
            capture = cap
            Log.write("armed on \(device.name) at \(Int(cap.sampleRate)) Hz")
            lastError = nil
            lastActivity = Date()
            state = .armed
            ensureTranscriber()
            startIdleTimer()
            if settings.composerDelivery { ComposerDelivery.warmUp() }
        } catch {
            lastError = "\(error)"
            Log.write("audio error: \(error)")
            hud.flash("Audio error", detail: "\(error)", tint: .red, icon: "exclamationmark.triangle", seconds: 3)
            onStateChange?()
        }
    }

    func disarm(reason: String? = nil) {
        guard state != .idle else { return }
        idleTimer?.invalidate()
        idleTimer = nil
        capture?.stop()
        capture = nil
        Log.write("idle" + (reason.map { ": \($0)" } ?? ""))
        state = .idle
        if let reason { hud.flash(reason, detail: "Listening is off. Press ⌃⌥Space or use the menu bar icon.", tint: .gray, icon: "mic.slash", seconds: 2.5) }
        else { hud.hide() }
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
            if limit > 0, Date().timeIntervalSince(self.lastActivity) > limit {
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

    private func process(_ frame: [Float]) {
        preroll.append(frame)
        if preroll.count > 20 { preroll.removeFirst() }

        let chirpEvents = chirps?.process(frame) ?? []
        let toneActive = chirps?.toneActive ?? false
        let rms = Levels.rmsDb(frame)

        // Handle markers from the mic's script: press opens the message, release sends it.
        for event in chirpEvents {
            guard case .onset(let target, _, _) = event else { continue }
            if target == "press" {
                lastActivity = Date()
                if !gate.isOpen { beginUtterance() }
                handleMode = true
                gate.forceOpenSilently()
                Log.write("handle pressed")
            } else if target == "cancel", handleMode {
                Log.write("shake: cancel")
                DispatchQueue.main.async { self.canceled = true; self.hud.canceled() }
            } else if target == "release", handleMode {
                Log.write("handle released")
                handleMode = false
                endUtterance(frames: openFrames)
                gate.forceClose()
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
                utterancePeak = max(utterancePeak, Levels.peakDb(frame))
            }
            transcriber?.feed(frame, sampleRate: sampleRate)
            if Double(openFrames) * hopSeconds > 90 {   // hard cap for a stuck handle
                Log.write("utterance cap reached, forcing close")
                endUtterance(frames: openFrames)
                gate.forceRelease()
            }
            if Date().timeIntervalSince(lastLevelPush) > 0.05 {
                lastLevelPush = Date()
                DispatchQueue.main.async { self.hud.model.level = rms }
            }
        }

        for event in chirpEvents {
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

    private func beginUtterance() {
        utteranceSerial += 1
        speechFrames = 0
        openFrames = 0
        utterancePeak = -160
        chirpDuringUtterance = false
        canceled = false
        partials = [:]
        lastActivity = Date()
        transcriber?.startUtterance()
        for f in preroll.dropLast() { transcriber?.feed(f, sampleRate: sampleRate) }
        state = .listening
        DispatchQueue.main.async { self.showListeningIfNeeded() }
    }

    private var hudShownForSerial = -1
    private func showListeningIfNeeded() {
        guard state == .listening, hudShownForSerial != utteranceSerial else { return }
        hudShownForSerial = utteranceSerial
        hud.listening(target: dispatcher.currentTarget?.title ?? "No session armed, will copy to clipboard")
    }

    private func endUtterance(frames: Int) {
        handleMode = false
        let speechSeconds = Double(speechFrames) * hopSeconds
        let serial = utteranceSerial
        let hadChirp = chirpDuringUtterance
        if speechSeconds >= 0.5 { autoTrim(peakDb: utterancePeak) }
        state = .armed
        guard let t = transcriber else {
            DispatchQueue.main.async { self.hud.flash("Transcriber not ready yet", tint: .yellow, icon: "hourglass") }
            return
        }
        DispatchQueue.main.async { self.pendingDeliveries += 1 }
        Task.detached { [self] in
            let result = await t.finishUtterance()
            // A tap during speech resolves up to 450 ms after the release; give it time to cancel.
            let delay: TimeInterval = hadChirp ? 0.6 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.pendingDeliveries -= 1
                self.deliver(result, speechSeconds: speechSeconds, serial: serial)
            }
        }
    }

    private func handle(_ update: TranscriptUpdate) {
        // Live text is not shown in the HUD any more; results are consumed in finishUtterance.
    }

    // MARK: delivery (main)

    private func deliver(_ result: UtteranceResult, speechSeconds: Double, serial: Int) {
        if canceled {
            Log.write("canceled: \(result.text)")
            canceled = false
            hud.hide(after: 0.3)   // the tap already flashed "Canceled"
            return
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 2, speechSeconds >= 0.4, result.confidence >= 0.35 else {
            Log.write(String(format: "dropped: %@ (%.1fs speech, conf %.2f)", text.isEmpty ? "empty" : text, speechSeconds, result.confidence))
            hud.hide(after: 0.2)
            return
        }
        let outcome: String
        if settings.composerDelivery, ComposerDelivery.isTrusted {
            do {
                try ComposerDelivery.send(text)
                outcome = "Sent to Claude"
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
        hud.sent(text, outcome: outcome)
        onRecentChange?()
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
            guard let self, let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(at: url)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { self.deliverText(trimmed) }
        }
    }

    // MARK: button gestures (main)

    private func tapAction(count: Int, duringSpeech: Bool) {
        Log.write("tap x\(count)\(duringSpeech ? " while squeezed (ignored)" : "")")
        if duringSpeech { return }          // cancel is a shake now; the button does nothing while the handle is in
        lastActivity = Date()
        if count == 1 { ClaudeApp.toggle() } else { disarm(reason: "Listening off") }
    }


    func newSession() {
        let folder = dispatcher.currentTarget?.cwd
        ClaudeApp.newCodeSession(folder: folder, prompt: "/fxmic")
        hud.flash("New Claude Code session", detail: folder ?? "Pick a folder in Claude", tint: .blue, icon: "plus.bubble", seconds: 2.5)
    }
}
