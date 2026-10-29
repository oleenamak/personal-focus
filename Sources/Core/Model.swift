import Foundation

enum EventType: String, Codable { case session, completion, retrospective }
enum TimeSource: String, Codable { case measured, estimated, unknown }

let allowedWorkTypes = ["Independent work", "Planning", "Agent review"]

/// One record in the daily log. The id is created once, stored in the recovery file before any
/// write is attempted, and reused on every retry, so a retry can never create a duplicate.
struct Event: Codable, Equatable {
    var id: String
    var taskId: String
    var type: EventType
    var workDate: String          // yyyy-MM-dd, America/Chicago
    var recordedAt: String        // ISO 8601 with offset
    var startedAt: String?
    var endedAt: String?
    var taskText: String
    var activeSeconds: Int?       // nil = unknown
    var timeSource: TimeSource
    var complete: Bool
    var workType: String?
    var note: String?
}

struct TaskItem: Codable, Equatable {
    var id: String
    var text: String
    var totalSeconds: Int         // time from earlier, already-logged sessions
}

struct ActiveRecord: Codable {
    var taskId: String
    var startedWall: Date
    var accumulated: Double       // active seconds at the last checkpoint
    var running: Bool             // true here after a restart means the app did not quit cleanly
    var checkpointWall: Date
}

struct DoneItem: Codable, Equatable {
    var date: String              // yyyy-MM-dd, America/Chicago
    var text: String
    var seconds: Int
    var note: String?
}

struct Persisted: Codable {
    var version = 1
    var tasks: [TaskItem] = []
    var active: ActiveRecord?
    var pending: [Event] = []
    var logFolder: String?
    var recentOps: [String] = []
    var lastSavedAt: Date?
    var done: [DoneItem]?         // tasks finished today, shown on the note; older days drop off
}

enum EngineError: Error, LocalizedError {
    case emptyTask, taskTooLong, taskNotFound, alreadyRunning(String), noActiveSession
    case invalidMinutes, invalidDate, futureDate, invalidWorkType

    var errorDescription: String? {
        switch self {
        case .emptyTask: return "Type a task first."
        case .taskTooLong: return "Keep the task under 200 characters."
        case .taskNotFound: return "That task is already done."
        case .alreadyRunning(let t): return "Stop \u{201C}\(t)\u{201D} before starting another task."
        case .noActiveSession: return "No task is running."
        case .invalidMinutes: return "Enter minutes as a number from 0 to 1440, or leave it blank."
        case .invalidDate: return "Enter a valid date (YYYY-MM-DD)."
        case .futureDate: return "Pick today or an earlier date."
        case .invalidWorkType: return "Pick one of the listed work types, or leave it blank."
        }
    }
}

// MARK: - Markdown

private func normalized(_ s: String) -> String {
    s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
}

/// Single-line text stays inline. Multi-line text becomes an indented blockquote, so a note can
/// never start a heading, a list item or an `- event:` line of its own.
private func field(_ label: String, _ text: String) -> [String] {
    let t = normalized(text)
    if !t.contains("\n") { return ["- \(label): \(t)"] }
    return ["- \(label):"] + t.split(separator: "\n", omittingEmptySubsequences: false).map { "  > \($0)" }
}

extension Event {
    static func eventLine(_ id: String) -> String { "- event: \(id)" }

    func markdown() -> String {
        let time = recordedAt.count >= 16 ? String(recordedAt.dropFirst(11).prefix(5)) : ""
        let titleSource = normalized(taskText).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let title = titleSource.count > 60 ? String(titleSource.prefix(60)) + "…" : titleSource
        var lines = ["### \(time) \(type.rawValue) · \(title)"]
        lines.append(Event.eventLine(id))
        lines.append("- task id: \(taskId)")
        lines.append("- type: \(type.rawValue)")
        lines.append("- work date: \(workDate)")
        lines.append("- recorded: \(recordedAt)")
        if let s = startedAt { lines.append("- started: \(s)") }
        if let e = endedAt { lines.append("- ended: \(e)") }
        lines += field("task", taskText)
        if let secs = activeSeconds {
            lines.append("- active seconds: \(secs)")
            lines.append("- active time: \(humanDuration(secs))")
        } else {
            lines.append("- active seconds: unknown")
        }
        lines.append("- time source: \(timeSource.rawValue)")
        lines.append("- complete: \(complete ? "yes" : "no")")
        if let w = workType, !w.isEmpty { lines.append("- work type: \(w)") }
        if let n = note, !n.isEmpty { lines += field("note", n) }
        return lines.joined(separator: "\n")
    }
}
