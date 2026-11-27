import AppKit
import ApplicationServices
import Foundation

/// Push-to-talk through the Claude app's own dictation, so a squeeze is transcribed by the same speech-to-text as
/// dictating in Claude by hand (Anthropic's server recognizer, with Claude's vocabulary hints), not by Apple's
/// on-device one. The squeeze presses the dictation button next to the composer, the release presses it again,
/// and the text Claude writes into the composer is taken back out and delivered like any transcript.
///
/// The button is found by label, near the composer, through the Accessibility API; the labels to look for are the
/// `dictationButtonLabels` setting, so a renamed button is a `defaults write`, not a rebuild. Every step runs on one
/// serial queue, so a squeeze's start always completes before its finish.
final class ClaudeDictation {
    enum Failure: Error, CustomStringConvertible {
        case notTrusted, claudeNotRunning, noComposer, noButton, notRunning, notSent
        var description: String {
            switch self {
            case .notSent: return "the composer still holds the text"
            case .notTrusted: return "Accessibility not granted"
            case .claudeNotRunning: return "Claude is not running"
            case .noComposer: return "composer not found"
            case .noButton: return "no dictation button next to the composer"
            case .notRunning: return "dictation was not started for this squeeze"
            }
        }
    }

    private typealias AX = ComposerDelivery
    private let queue = DispatchQueue(label: "fxmic.dictation")
    private struct Run {
        let serial: Int
        let axApp: AXUIElement
        var window: AXUIElement
        var composer: AXUIElement
        let buttonCenter: CGPoint
        let idleLabel: String
        var labelChanged = false
        /// What the composer held when the squeeze began: a draft, or "".
        let before: String
    }
    private var run: Run?
    /// The last finished squeeze, whose text is still in the composer until `complete` decides what to do with it.
    private var finished: Run?
    private var poll: DispatchSourceTimer?
    private var lastPartial = ""

    /// Live text while Claude listens, read from the composer (called on main).
    var onPartial: ((String) -> Void)?

    // MARK: start

    /// Switches to the target session, presses the dictation button, and reports when Claude is listening, with the
    /// title of the session it is listening in (the one on screen when the target could not be shown).
    func start(serial: Int, target: String?, attempt: Int = 0, onStarted: @escaping (Result<String, Failure>) -> Void) {
        queue.async { [self] in
            // The last squeeze's text is still in the composer waiting to be sent, queued, kept or removed: let that
            // finish first (up to 3 s), so the two messages never mix.
            if finished != nil, attempt < 30 {
                queue.asyncAfter(deadline: .now() + 0.1) {
                    self.start(serial: serial, target: target, attempt: attempt + 1, onStarted: onStarted)
                }
                return
            }
            if attempt >= 30 { Log.write("dictation: the last squeeze was never completed, starting anyway") }
            stopPolling()
            run = nil
            finished = nil
            let result = begin(serial: serial, target: target)
            DispatchQueue.main.async { onStarted(result) }
        }
    }

    private func begin(serial: Int, target: String?) -> Result<String, Failure> {
        guard AX.isTrusted else { return .failure(.notTrusted) }
        guard let app = ClaudeApp.running else { return .failure(.claudeNotRunning) }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let target, let found = ComposerDelivery.locateComposer(axApp) {
            do { try ComposerDelivery.switchToSession(titled: target, in: found.window) } catch {
                Log.write("dictation: could not switch to \(target) (\(error)), using the session on screen")
            }
        }
        guard let found = ComposerDelivery.locateComposer(axApp) else { return .failure(.noComposer) }
        let window = found.window, composer = found.composer

        let labels = Settings.shared.dictationButtonLabels.map { $0.lowercased() }
        let candidates = buttonsNear(composer, in: window).filter { el in
            let l = label(el).lowercased()
            return labels.contains { l.contains($0) } && !l.contains("voice mode")
        }
        guard let button = candidates.first else {
            logButtons(window: window, composer: composer, why: "no match for \(labels)")
            return .failure(.noButton)
        }
        let idleLabel = label(button)
        let f = AX.frame(button)
        let before = composerText(composer)
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { return .failure(.noButton) }
        var current = Run(serial: serial, axApp: axApp, window: window, composer: composer,
                          buttonCenter: CGPoint(x: f.midX, y: f.midY), idleLabel: idleLabel, before: before)
        // Listening shows as a change of the button's label ("Stop dictation" and the like). Up to 2 s.
        var nowLabel = idleLabel
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            nowLabel = buttonLabel(current) ?? idleLabel
            if nowLabel != idleLabel { current.labelChanged = true; break }
        }
        run = current
        Log.write("dictation: pressed \"\(idleLabel)\"" + (current.labelChanged ? ", now \"\(nowLabel)\"" : ", label unchanged after 2 s")
                  + (before.isEmpty ? "" : ", composer draft kept aside (\(before.count) chars)"))
        startPolling()
        return .success(ComposerDelivery.activeSessionTitle(in: window) ?? "")
    }

    // MARK: finish

    /// Presses the button again, waits for Claude's final text, and returns it. The text stays in the composer, where
    /// Claude put it, until `complete` sends, queues, keeps or removes it.
    func finish(serial: Int, completion: @escaping (Result<String, Failure>) -> Void) {
        queue.async { [self] in
            stopPolling()
            guard let current = run, current.serial == serial else {
                DispatchQueue.main.async { completion(.failure(.notRunning)) }
                return
            }
            run = nil
            var r = current
            let text = end(&r)
            finished = r
            DispatchQueue.main.async { completion(.success(text)) }
        }
    }

    /// Stops a dictation in progress and discards its text (hang-up mid-squeeze).
    func abort() {
        queue.async { [self] in
            stopPolling()
            guard let current = run else { return }
            run = nil
            var r = current
            let text = end(&r)
            restore(&r)
            Log.write("dictation: aborted, \(text.count) chars discarded")
        }
    }

    private var dictationLabels: [String] { Settings.shared.dictationButtonLabels.map { $0.lowercased() } }

    private func end(_ r: inout Run) -> String {
        let pressedAt = Date()
        if let button = button(at: r.buttonCenter, in: r.window) {
            let l = label(button)
            // Press only the dictation control, and only while it is listening: a control that moved there, or a
            // dictation Claude already stopped (a press would start it again), is left alone.
            let lower = l.lowercased()
            let isDictation = lower.contains("dictat") || dictationLabels.contains { lower.contains($0) }
            if !isDictation {
                Log.write("dictation: the control at the dictation button's place is \"\(l)\", not pressed")
            } else if r.labelChanged, l == r.idleLabel {
                Log.write("dictation: Claude had already stopped listening, not pressed")
            } else if AXUIElementPerformAction(button, kAXPressAction as CFString) != .success {
                Log.write("dictation: stop press failed on \"\(l)\"")
            } else {
                Log.write("dictation: pressed \"\(l)\" to finish")
            }
        } else {
            Log.write("dictation: button gone at finish")
        }
        // Done when the button is back to its idle label and the text has stopped changing. If the label never
        // changed (nothing to watch), the text has to hold still longer.
        var last = ""
        var lastChange = Date()
        let settle: TimeInterval = r.labelChanged ? 0.35 : 1.2
        let emptyWait: TimeInterval = r.labelChanged ? 2.0 : 4.0
        while Date().timeIntervalSince(pressedAt) < 10 {
            Thread.sleep(forTimeInterval: 0.15)
            let text = dictated(value(&r), before: r.before)
            if text != last { last = text; lastChange = Date() }
            let idle = !r.labelChanged || buttonLabel(r) == r.idleLabel
            let still = Date().timeIntervalSince(lastChange)
            if idle, still >= settle, !last.isEmpty || Date().timeIntervalSince(pressedAt) > emptyWait { break }
            if !idle, still >= 3, !last.isEmpty { Log.write("dictation: button still busy, text settled"); break }
        }
        Log.write(String(format: "dictation: finished in %.1f s, %d chars", Date().timeIntervalSince(pressedAt), last.count))
        return last
    }

    // MARK: complete

    enum Action { case keep, send, queue, discard }
    enum Outcome { case kept, sent, queued, discarded }

    /// What happens to the text Claude left in the composer: kept as a draft, sent with the Send button (queued when
    /// the session is busy and shows Stop instead), queued in Claude with Cmd+Return, or removed. A failed send or
    /// queue puts the composer back as it was before the squeeze, so the caller can deliver the text another way.
    func complete(serial: Int, action: Action, completion: @escaping (Result<Outcome, Failure>) -> Void) {
        queue.async { [self] in
            guard var r = finished, r.serial == serial else {
                DispatchQueue.main.async { completion(.failure(.notRunning)) }
                return
            }
            finished = nil
            let result: Result<Outcome, Failure>
            switch action {
            case .keep:
                result = .success(.kept)
            case .discard:
                restore(&r)
                result = .success(.discarded)
            case .send, .queue:
                if action == .send, let send = buttonNear(r, labeled: "Send") {
                    AXUIElementPerformAction(send, kAXPressAction as CFString)
                    result = composerEmpties(&r) ? .success(.sent) : .failure(.notSent)
                } else {
                    if action == .send { Log.write("dictation: no Send button (session busy), queueing instead") }
                    result = queueInClaude(&r) ? .success(.queued) : .failure(.notSent)
                }
                if case .failure = result { restore(&r) }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Claude's own queue: Cmd+Return in the composer, sent to the Claude process without bringing it forward.
    private func queueInClaude(_ r: inout Run) -> Bool {
        guard let app = ClaudeApp.running else { return false }
        AXUIElementSetAttributeValue(r.composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.05)
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)   // Return
            event?.flags = .maskCommand
            event?.postToPid(app.processIdentifier)
        }
        let ok = composerEmpties(&r)
        Log.write(ok ? "dictation: queued in Claude with Cmd+Return" : "dictation: Cmd+Return left the text in the composer")
        return ok
    }

    private func composerEmpties(_ r: inout Run) -> Bool {
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.12)
            if value(&r).isEmpty { return true }
        }
        return false
    }

    private func buttonNear(_ r: Run, labeled description: String) -> AXUIElement? {
        buttonsNear(r.composer, in: r.window).first { AX.string($0, kAXDescriptionAttribute) == description }
    }

    /// Leaves the composer holding what it held before the squeeze.
    private func restore(_ r: inout Run) {
        let composer = r.composer
        AXUIElementSetAttributeValue(composer, kAXValueAttribute as CFString, r.before as CFString)
        Thread.sleep(forTimeInterval: 0.15)
        if composerText(composer) == r.before { return }
        // An empty value set does not always reach the web view; select everything and replace the selection.
        let length = AX.string(composer, kAXValueAttribute).utf16.count
        var range = CFRange(location: 0, length: length)
        if let rangeValue = AXValueCreate(.cfRange, &range) {
            AXUIElementSetAttributeValue(composer, kAXSelectedTextRangeAttribute as CFString, rangeValue)
            AXUIElementSetAttributeValue(composer, kAXSelectedTextAttribute as CFString, r.before as CFString)
        }
        Thread.sleep(forTimeInterval: 0.15)
        let now = composerText(composer)
        Log.write(now == r.before ? "dictation: composer restored by selection" : "dictation: composer not restored, holds \(now.count) chars")
    }

    // MARK: live text

    private func startPolling() {
        lastPartial = ""
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.3, repeating: 0.3)
        timer.setEventHandler { [weak self] in
            guard let self, var r = self.run else { return }
            let text = self.dictated(self.value(&r), before: r.before)
            self.run = r
            guard text != self.lastPartial else { return }
            self.lastPartial = text
            DispatchQueue.main.async { self.onPartial?(text) }
        }
        timer.resume()
        poll = timer
    }

    private func stopPolling() { poll?.cancel(); poll = nil }

    // MARK: diagnostics

    /// Logs every button near the composer with its labels and position (also on demand: touch ~/.fxmic/axdump).
    func dump() {
        queue.async { [self] in
            guard AX.isTrusted, let app = ClaudeApp.running else { Log.write("axdump: no access or Claude not running"); return }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            guard let found = ComposerDelivery.locateComposer(axApp) else { Log.write("axdump: composer not found"); return }
            logButtons(window: found.window, composer: found.composer, why: "requested")
        }
    }

    private func logButtons(window: AXUIElement, composer: AXUIElement, why: String) {
        let composers = AX.find(window, depth: 0) { AX.role($0) == "AXTextArea" && AX.string($0, kAXDescriptionAttribute) == "Prompt" }
        var out = "dictation: controls near the composer (\(why)); \(composers.count) composer(s) in the window, using the first"
        for (i, c) in composers.enumerated() {
            let cf = AX.frame(c)
            out += String(format: "\n composer %d at %.0f,%.0f %.0fx%.0f%@", i, cf.minX, cf.minY, cf.width, cf.height,
                          (AX.attribute(c, kAXFocusedAttribute) as? Bool) == true ? " (focused)" : "")
            let near = AX.find(window, depth: 0) { el in
                let f = AX.frame(el)
                guard f.width > 0, f.height > 0, f.width < 200, f.maxY >= cf.minY - 80, f.minY <= cf.maxY + 80 else { return false }
                return !["AXGroup", "AXStaticText", "AXTextArea", "AXUnknown", "AXImage", "AXWebArea", "AXScrollArea"].contains(AX.role(el)) || !self.label(el).isEmpty
            }
            for el in near {
                let f = AX.frame(el)
                out += String(format: "\n   %@ \"%@\" at %.0f,%.0f %.0fx%.0f", self.kind(el), self.label(el), f.minX, f.minY, f.width, f.height)
            }
        }
        Log.write(out)
    }

    // MARK: helpers

    private func label(_ el: AXUIElement) -> String {
        let classes = (AX.attribute(el, "AXDOMClassList") as? [String])?.joined(separator: ".") ?? ""
        return [AX.string(el, kAXDescriptionAttribute), AX.string(el, kAXTitleAttribute), AX.string(el, kAXHelpAttribute),
                AX.string(el, "AXDOMIdentifier"), classes.isEmpty ? "" : "." + classes]
            .filter { !$0.isEmpty }.joined(separator: " | ")
    }

    private func kind(_ el: AXUIElement) -> String {
        let sub = AX.string(el, kAXSubroleAttribute)
        return AX.role(el) + (sub.isEmpty ? "" : "/" + sub)
    }

    private static let pressable: Set<String> = ["AXButton", "AXCheckBox", "AXToggle", "AXMenuButton", "AXPopUpButton", "AXRadioButton"]

    private func buttonsNear(_ composer: AXUIElement, in window: AXUIElement) -> [AXUIElement] {
        let cf = AX.frame(composer)
        return AX.find(window, depth: 0) { el in
            guard Self.pressable.contains(AX.role(el)) else { return false }
            let f = AX.frame(el)
            return f.width > 0 && f.maxY >= cf.minY - 60 && f.minY <= cf.maxY + 80
        }
    }

    private func button(at center: CGPoint, in window: AXUIElement) -> AXUIElement? {
        AX.find(window, depth: 0) { el in
            guard Self.pressable.contains(AX.role(el)) else { return false }
            let f = AX.frame(el)
            return abs(f.midX - center.x) < 6 && abs(f.midY - center.y) < 6
        }.first
    }

    private func buttonLabel(_ r: Run) -> String? { button(at: r.buttonCenter, in: r.window).map(label) }

    /// The composer's text, with the empty composer's placeholder read as "".
    private func composerText(_ composer: AXUIElement) -> String {
        let v = AX.string(composer, kAXValueAttribute).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.lowercased().hasPrefix("type /") ? "" : v
    }

    /// Reads the composer, finding it again if the web view replaced the element.
    private func value(_ r: inout Run) -> String {
        var v: AnyObject?
        if AXUIElementCopyAttributeValue(r.composer, kAXValueAttribute as CFString, &v) != .success,
           let found = ComposerDelivery.locateComposer(r.axApp) {
            r.window = found.window
            r.composer = found.composer
        }
        return composerText(r.composer)
    }

    /// What dictation added: the composer text minus the draft it held before.
    private func dictated(_ value: String, before: String) -> String {
        guard !before.isEmpty else { return value }
        if value.hasPrefix(before) { return String(value.dropFirst(before.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let range = value.range(of: before) {
            var rest = value
            rest.removeSubrange(range)
            return rest.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }
}
