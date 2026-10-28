import Foundation
import CryptoKit

/// Two clocks: `monotonic` measures working time (it does not advance while the Mac sleeps),
/// `wall` is only used for dates and timestamps.
protocol Clock {
    var monotonic: TimeInterval { get }
    var wall: Date { get }
}

struct SystemClock: Clock {
    var monotonic: TimeInterval { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000 }
    var wall: Date { Date() }
}

/// Controlled clock for tests. `advance` moves both clocks; `advanceWallOnly` models downtime
/// (quit, crash or sleep) that must never count as work.
final class TestClock: Clock {
    var monotonic: TimeInterval = 1000
    var wall: Date
    init(wall: Date) { self.wall = wall }
    func advance(_ seconds: TimeInterval) {
        monotonic += seconds
        wall = wall.addingTimeInterval(seconds)
    }
    func advanceWallOnly(_ seconds: TimeInterval) {
        wall = wall.addingTimeInterval(seconds)
    }
}

/// All dates in the log are America/Chicago.
enum Chicago {
    static let tz = TimeZone(identifier: "America/Chicago")!

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = format
        return f
    }

    static func dateString(_ d: Date) -> String { formatter("yyyy-MM-dd").string(from: d) }
    static func timeString(_ d: Date) -> String { formatter("HH:mm").string(from: d) }
    static func label(_ d: Date) -> String { formatter("EEEE, MMM d").string(from: d) }

    /// ISO 8601 with the UTC offset, e.g. 2026-10-28T10:42:07-05:00
    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = tz
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    static func make(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = mi; c.second = s
        c.timeZone = tz
        return calendar.date(from: c)!
    }

    /// Strict yyyy-MM-dd parse; returns nil for anything that is not a real calendar date.
    static func parseDate(_ s: String) -> String? {
        guard s.count == 10, s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        guard let d = formatter("yyyy-MM-dd").date(from: s), dateString(d) == s else { return nil }
        return s
    }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func shortID(_ prefix: String) -> String {
    prefix + "-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
}

func humanDuration(_ seconds: Int) -> String {
    let s = max(0, seconds)
    if s < 60 { return "\(s)s" }
    let h = s / 3600, m = (s % 3600) / 60, r = s % 60
    if h > 0 { return r == 0 ? "\(h)h \(m)m" : "\(h)h \(m)m \(r)s" }
    return r == 0 ? "\(m)m" : "\(m)m \(r)s"
}

func clockString(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let h = s / 3600, m = (s % 3600) / 60, r = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%02d:%02d", m, r)
}
