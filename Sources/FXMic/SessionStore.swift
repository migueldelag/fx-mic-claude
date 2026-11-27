import Foundation

/// Claude desktop Code sessions, read from the desktop app's own per-session files.
struct ClaudeSession {
    let id: String
    let title: String
    let lastUsed: Date
}

enum SessionStore {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")

    /// Whether the session with this title is in the middle of a turn, from the desktop app's own session file:
    /// while a turn runs, the latest user message is newer than the last turn edge (start or end of a turn); once
    /// the turn ends, the edge is newer. nil when the session or the fields are not found. Undocumented app
    /// internals, so callers treat nil as "not running" and keep a timeout.
    static func isRunning(title: String) -> Bool? {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var best: (date: Date, running: Bool)?
        for case let url as URL in files where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["title"] as? String == title, (obj["isArchived"] as? Bool) != true,
                  let user = (obj["latestUserFrameAt"] as? NSNumber)?.doubleValue,
                  let edge = (obj["lastTurnEdgeAt"] as? NSNumber)?.doubleValue else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if best == nil || date > best!.date { best = (date, user >= edge) }
        }
        return best?.running
    }

    /// The session used most recently (last focused in the desktop app).
    static func lastUsed() -> ClaudeSession? { recent(limit: 1).first }

    /// Most recently focused sessions first, archived ones excluded.
    static func recent(limit: Int = 5) -> [ClaudeSession] {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        var sessions: [ClaudeSession] = []
        for case let url as URL in files where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["sessionId"] as? String,
                  let title = obj["title"] as? String, !title.isEmpty,
                  (obj["isArchived"] as? Bool) != true else { continue }
            // Timestamps are epoch milliseconds in current builds; accept ISO strings too.
            func date(_ v: Any?) -> Date? {
                if let n = v as? Double { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
                if let s = v as? String { return iso.date(from: s) ?? isoPlain.date(from: s) }
                return nil
            }
            let date = date(obj["lastFocusedAt"]) ?? date(obj["lastActivityAt"])
                ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            sessions.append(ClaudeSession(id: id, title: title, lastUsed: date))
        }
        return Array(sessions.sorted { $0.lastUsed > $1.lastUsed }.prefix(limit))
    }
}
