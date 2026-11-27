import Darwin
import Foundation

/// Squeeze events from the mic's script over its USB serial console, so FXMic can keep the Mac's audio input closed
/// between squeezes. The script prints one line per event ("fxmic press", "fxmic release", ...) and "fxmic hi"
/// about every 2 s. The port counts as live while such lines keep arriving; a mic on batteries, an old script or a
/// charge-only cable sends none, and FXMic then listens for the marker tones as before.
///
/// Read only. FXMic never writes to the port (a byte would reach the mic's REPL and could stop its script) and never
/// changes the modem lines (toggling DTR/RTS resets the mic). It opens and sets the port up the way
/// tools/mp_exec.py does, and holds it exclusively: quit FXMic before running tools that use the console.
public final class MicSerial {
    public enum Event: String { case hi, press, release, queue, draft, cancel, tap }

    /// Called on the serial queue. A change of `live` is always reported before the event that caused it.
    public var onEvent: ((Event) -> Void)?
    public var onLiveChange: ((Bool) -> Void)?
    public var log: ((String) -> Void)?

    public private(set) var live = false
    public private(set) var portPath: String?

    private let match: String
    private let queue = DispatchQueue(label: "fxmic.serial")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var pending = Data()
    private var lastLine = Date.distantPast
    private var failedPath: String?
    /// No line for this long: the script stopped reporting (mic off, cable out, old script).
    private let liveTimeout: TimeInterval = 5

    /// `match` must appear in the port's name; the EP-2350 enumerates as /dev/cu.usbmodemEP…. Other boards' ports
    /// are never opened (opening one can reset it). A full /dev path is used as is (tests use a pseudo-terminal).
    public init(match: String = "usbmodemEP") {
        self.match = match
    }

    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 1)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    public func stop() {
        queue.async { [self] in
            timer?.cancel(); timer = nil
            close(reason: nil)
        }
    }

    private func tick() {
        if fd < 0, let path = findPort() { open(path) }
        if live, Date().timeIntervalSince(lastLine) > liveTimeout { setLive(false) }
    }

    private func findPort() -> String? {
        if match.hasPrefix("/dev/") { return FileManager.default.fileExists(atPath: match) ? match : nil }   // tests
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let path = names.filter { $0.hasPrefix("cu.") && $0.contains(match) }.sorted().first.map { "/dev/" + $0 }
        if path == nil { failedPath = nil }
        return path
    }

    private func open(_ path: String) {
        let f = Darwin.open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else {
            if failedPath != path { log?("usb: cannot open \(path): \(String(cString: strerror(errno)))") }
            failedPath = path
            return
        }
        // Raw bytes, no echo, ignore carrier: the same as `stty raw -echo clocal` in tools/mp_exec.py. The speed is
        // nominal on a USB console. HUPCL is left as it is.
        var t = termios()
        if tcgetattr(f, &t) == 0 {
            let hupcl = t.c_cflag & tcflag_t(HUPCL)
            cfmakeraw(&t)
            t.c_cflag |= tcflag_t(CLOCAL | CREAD)
            t.c_cflag = (t.c_cflag & ~tcflag_t(HUPCL)) | hupcl
            cfsetspeed(&t, speed_t(B115200))
            tcsetattr(f, TCSANOW, &t)
        }
        // Exclusive: a second reader (tools/mp_exec.py) would split the console's bytes with FXMic. It gets "busy"
        // instead and asks for FXMic to be quit first.
        _ = ioctl(f, 0x2000_740D)        // TIOCEXCL, _IO('t', 13)
        fd = f
        portPath = path
        failedPath = nil
        pending.removeAll()
        log?("usb: watching \(path) for squeeze reports")
        let s = DispatchSource.makeReadSource(fileDescriptor: f, queue: queue)
        s.setEventHandler { [weak self] in self?.readAvailable() }
        s.resume()
        source = s
    }

    private func close(reason: String?) {
        source?.cancel(); source = nil
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        if let reason, let portPath { log?("usb: \(portPath) closed (\(reason))") }
        portPath = nil
        pending.removeAll()
        setLive(false)
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 1024)
        while fd >= 0 {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                pending.append(buf, count: n)
                continue
            }
            if n == 0 || (errno != EAGAIN && errno != EINTR) {
                close(reason: n == 0 ? "end of file" : String(cString: strerror(errno)))   // unplugged or powered off
            }
            break
        }
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...nl)
            handle(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if pending.count > 4096 { pending.removeAll() }        // no newline in sight: not our script's output
    }

    /// Only "fxmic <event>" lines count. Anything else the mic prints (REPL banner, errors) is ignored and never logged.
    private func handle(_ line: String) {
        let parts = line.split(separator: " ")
        guard parts.count == 2, parts[0] == "fxmic", let event = Event(rawValue: String(parts[1])) else { return }
        lastLine = Date()
        setLive(true)
        onEvent?(event)
    }

    private func setLive(_ value: Bool) {
        guard value != live else { return }
        live = value
        onLiveChange?(value)
    }
}
