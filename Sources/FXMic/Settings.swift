import Foundation

/// User-adjustable values, stored in UserDefaults under the app's bundle id (or the binary name when run bare).
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "deviceQuery": "USB Advanced Audio Device",
            "locales": ["en-US", "es-MX"],
            "idleMinutes": 20,
            "openDb": -44.0,
            "chirpMinLevelDb": -50.0,
            "closeDb": -50.0,
            "chirpFreqs": [15500.0, 16500.0],
            "pressFreqs": [17000.0, 18500.0],
            "releaseFreqs": [14000.0, 15000.0],
            "cancelFreqs": [12000.0, 13000.0],
            "autoArm": true,
            "hudEnabled": true,
            "hudTranscript": true,
            "transcriberGainDb": 0.0,
            "fastLiveText": false,
            "livePreview": true,
            "autoGain": true,
            "composerDelivery": true,
            "transcriptionEngine": "apple",
            "dictationButtonLabels": ["hold to record", "dictat"],
            "shakeToCancel": true,
            "usbTrigger": true,
            "stuckSqueezeSeconds": 30.0,
            "appleFallback": true,
            "statusBadge": true,
            "iconIdle": "phone.down.fill",
            "iconArmed": "phone.fill",
            "iconListening": "phone.and.waveform.fill",
        ])
    }

    var deviceQuery: String { get { d.string(forKey: "deviceQuery") ?? "USB Advanced Audio Device" } set { d.set(newValue, forKey: "deviceQuery") } }
    var locales: [String] { get { d.stringArray(forKey: "locales") ?? ["en-US", "es-MX"] } set { d.set(newValue, forKey: "locales") } }
    var idleMinutes: Double { get { d.double(forKey: "idleMinutes") } set { d.set(newValue, forKey: "idleMinutes") } }
    var openDb: Float { get { Float(d.double(forKey: "openDb")) } set { d.set(Double(newValue), forKey: "openDb") } }
    var closeDb: Float { get { Float(d.double(forKey: "closeDb")) } set { d.set(Double(newValue), forKey: "closeDb") } }
    /// Weakest marker tone that counts. Lower it for quiet input paths; the guard-bin SNR test still rejects speech.
    var chirpMinLevelDb: Float { get { Float(d.double(forKey: "chirpMinLevelDb")) } set { d.set(Double(newValue), forKey: "chirpMinLevelDb") } }
    /// Numbers, or numeric strings as `defaults write <domain> <key> -array 4300 5700` stores them.
    private func doubles(_ key: String) -> [Double]? {
        guard let items = d.array(forKey: key) else { return nil }
        let values = items.compactMap { ($0 as? NSNumber)?.doubleValue ?? ($0 as? String).flatMap(Double.init) }
        return values.count == items.count && !values.isEmpty ? values : nil
    }
    var chirpFreqs: [Double] { get { doubles("chirpFreqs") ?? [15500, 16500] } set { d.set(newValue, forKey: "chirpFreqs") } }
    var pressFreqs: [Double] { get { doubles("pressFreqs") ?? [17000, 18500] } set { d.set(newValue, forKey: "pressFreqs") } }
    var cancelFreqs: [Double] { get { doubles("cancelFreqs") ?? [12000, 13000] } set { d.set(newValue, forKey: "cancelFreqs") } }
    var releaseFreqs: [Double] { get { doubles("releaseFreqs") ?? [14000, 15000] } set { d.set(newValue, forKey: "releaseFreqs") } }
    var autoArm: Bool { get { d.bool(forKey: "autoArm") } set { d.set(newValue, forKey: "autoArm") } }
    var hudEnabled: Bool { get { d.bool(forKey: "hudEnabled") } set { d.set(newValue, forKey: "hudEnabled") } }
    /// Show the live transcript in the Listening bar.
    var hudTranscript: Bool { get { d.bool(forKey: "hudTranscript") } set { d.set(newValue, forKey: "hudTranscript") } }
    /// A separate fast recognizer feeds the live text in the bar; the sent text still comes from the accurate one.
    var livePreview: Bool { get { d.bool(forKey: "livePreview") } set { d.set(newValue, forKey: "livePreview") } }
    /// Faster results from every recognizer, the sent text included, at some cost in its accuracy
    /// (SpeechTranscriber .fastResults). Off by default; livePreview gives fast live text without that cost.
    var fastLiveText: Bool { get { d.bool(forKey: "fastLiveText") } set { d.set(newValue, forKey: "fastLiveText") } }
    /// Gain applied to the audio fed to the speech recognizer only (clipped at full scale). Quiet inputs recognize
    /// better with +20 dB: on recordings peaking at -36 to -43 dBFS, confidence rose from 0.75-0.79 to 0.87-0.88
    /// on the weaker sentences.
    var transcriberGainDb: Float { get { Float(d.double(forKey: "transcriberGainDb")) } set { d.set(Double(newValue), forKey: "transcriberGainDb") } }
    var autoGain: Bool { get { d.bool(forKey: "autoGain") } set { d.set(newValue, forKey: "autoGain") } }
    var iconIdle: String { d.string(forKey: "iconIdle") ?? "phone.down.fill" }
    var iconArmed: String { d.string(forKey: "iconArmed") ?? "phone.fill" }
    var iconListening: String { d.string(forKey: "iconListening") ?? "phone.and.waveform.fill" }
    /// Title of the Claude session that receives messages; nil means whatever session was used last.
    var targetSessionTitle: String? { get { d.string(forKey: "targetSessionTitle") } set { d.set(newValue, forKey: "targetSessionTitle") } }
    /// Dots while the session works and a check when it finishes, drawn on the menu bar icon.
    var statusBadge: Bool { get { d.bool(forKey: "statusBadge") } set { d.set(newValue, forKey: "statusBadge") } }
    var shakeToCancel: Bool { get { d.bool(forKey: "shakeToCancel") } set { d.set(newValue, forKey: "shakeToCancel") } }
    var composerDelivery: Bool { get { d.bool(forKey: "composerDelivery") } set { d.set(newValue, forKey: "composerDelivery") } }
    /// "apple": Apple's on-device recognizer transcribes. "claude": a squeeze drives the Claude app's own dictation
    /// (the same server speech-to-text as dictating in Claude by hand); Apple's runs alongside as the fallback.
    var transcriptionEngine: String { get { d.string(forKey: "transcriptionEngine") ?? "apple" } set { d.set(newValue, forKey: "transcriptionEngine") } }
    /// Case-insensitive pieces of the dictation button's accessibility label, any of which identifies it.
    var dictationButtonLabels: [String] { d.stringArray(forKey: "dictationButtonLabels") ?? ["hold to record", "dictat"] }
    /// Take squeezes from the mic's USB serial console when it reports them, and keep the audio input closed between
    /// squeezes. Without reports (mic on batteries, old script) FXMic listens for the marker tones.
    /// A squeeze with no speech for this long and no release heard ends as a draft (a missed release tone). 0 = never.
    var stuckSqueezeSeconds: Double { d.double(forKey: "stuckSqueezeSeconds") }
    var usbTrigger: Bool { get { d.bool(forKey: "usbTrigger") } set { d.set(newValue, forKey: "usbTrigger") } }
    /// With Claude's dictation: also run Apple's on-device recognizer on each squeeze, used when Claude's text is
    /// missing. Off means FXMic does not transcribe at all (and, with squeezes over USB, never opens the input).
    /// Piece of the mic's serial port name, or a full /dev path. Change it only for tests.
    var usbPort: String { d.string(forKey: "usbPort") ?? "usbmodemEP" }
    var appleFallback: Bool { get { d.bool(forKey: "appleFallback") } set { d.set(newValue, forKey: "appleFallback") } }
    var selectedTargetID: String? { get { d.string(forKey: "selectedTargetID") } set { d.set(newValue, forKey: "selectedTargetID") } }
}
