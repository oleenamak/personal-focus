import Foundation

/// The whole app model: tasks, one running session, pending log events and recovery state.
/// Every change that matters is written to the recovery file before the app reports it.
final class Engine {
    private struct Active {
        var taskId: String
        var startedWall: Date
        var accumulated: Double
        var runningSince: TimeInterval?
    }

    let clock: Clock
    let stateURL: URL
    let store: LogStore

    private(set) var tasks: [TaskItem] = []
    private var active: Active?
    private(set) var pending: [Event] = []
    private(set) var logFolder: URL
    private(set) var lastError: String?
    private(set) var lastSavedAt: Date?
    private(set) var persistCount = 0
    var notice: String?

    private var recentOps: [String] = []
    private var lastCheckpoint: TimeInterval = 0
    private let checkpointInterval: TimeInterval = 5

    init(clock: Clock, stateURL: URL, defaultFolder: URL, store: LogStore = LogStore()) {
        self.clock = clock
        self.stateURL = stateURL
        self.store = store
        self.logFolder = defaultFolder
        self.lastCheckpoint = clock.monotonic
        load()
    }

    // MARK: Recovery state

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stateURL.path) else { return }
        guard let data = fm.contents(atPath: stateURL.path),
              let p = try? JSONDecoder.pf.decode(Persisted.self, from: data) else {
            let copy = stateURL.deletingLastPathComponent()
                .appendingPathComponent("state.unreadable-\(Int(clock.wall.timeIntervalSince1970)).json")
            try? fm.moveItem(at: stateURL, to: copy)
            notice = "Your saved state couldn't be read, so the app started empty. The old file was kept as \(copy.lastPathComponent)."
            return
        }
        tasks = p.tasks
        pending = p.pending
        recentOps = p.recentOps
        lastSavedAt = p.lastSavedAt
        if let f = p.logFolder, !f.isEmpty { logFolder = URL(fileURLWithPath: f) }
        if let a = p.active {
            active = Active(taskId: a.taskId, startedWall: a.startedWall, accumulated: a.accumulated, runningSince: nil)
            let at = Int(a.accumulated.rounded())
            if a.running {
                let gap = max(0, Int(clock.wall.timeIntervalSince(a.checkpointWall)))
                notice = "The app closed unexpectedly. Your timer is paused at \(clockString(at)). Up to \(humanDuration(gap)) of work after the last checkpoint (\(Chicago.timeString(a.checkpointWall))) may be missing, and none of it was counted."
            } else {
                notice = "Your timer was paused when the app closed, at \(clockString(at))."
            }
        }
    }

    private func persist() {
        persistCount += 1
        var rec: ActiveRecord?
        if let a = active {
            rec = ActiveRecord(taskId: a.taskId, startedWall: a.startedWall, accumulated: activeSeconds(),
                               running: a.runningSince != nil, checkpointWall: clock.wall)
        }
        let p = Persisted(tasks: tasks, active: rec, pending: pending, logFolder: logFolder.path,
                          recentOps: recentOps, lastSavedAt: lastSavedAt)
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.pf.encode(p).write(to: stateURL, options: .atomic)
            lastCheckpoint = clock.monotonic
        } catch {
            lastError = "Couldn't write the recovery file: \(error.localizedDescription)"
        }
    }

    /// Called about once a second. Writes a checkpoint at most every five seconds while running.
    func tick() {
        if let a = active, a.runningSince != nil, clock.monotonic - lastCheckpoint >= checkpointInterval {
            persist()
        }
    }

    // MARK: Timer

    func activeSeconds() -> Double {
        guard let a = active else { return 0 }
        if let r = a.runningSince { return a.accumulated + max(0, clock.monotonic - r) }
        return a.accumulated
    }

    var isRunning: Bool { active?.runningSince != nil }
    var hasActive: Bool { active != nil }

    @discardableResult
    func addTask(_ raw: String) throws -> TaskItem {
        let text = raw.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw EngineError.emptyTask }
        guard text.count <= 200 else { throw EngineError.taskTooLong }
        let t = TaskItem(id: shortID("t"), text: text, totalSeconds: 0)
        tasks.append(t)
        persist()
        return t
    }

    func start(_ taskId: String) throws {
        if let a = active, let t = tasks.first(where: { $0.id == a.taskId }) { throw EngineError.alreadyRunning(t.text) }
        guard tasks.contains(where: { $0.id == taskId }) else { throw EngineError.taskNotFound }
        active = Active(taskId: taskId, startedWall: clock.wall, accumulated: 0, runningSince: clock.monotonic)
        notice = nil
        persist()
    }

    func pause() {
        guard var a = active, let r = a.runningSince else { return }
        a.accumulated += max(0, clock.monotonic - r)
        a.runningSince = nil
        active = a
        persist()
    }

    func resume() {
        guard var a = active, a.runningSince == nil else { return }
        a.runningSince = clock.monotonic
        active = a
        notice = nil
        persist()
    }

    func stop() throws {
        guard active != nil else { throw EngineError.noActiveSession }
        let ev = endSession(complete: false, note: nil, workType: nil)
        pending.append(ev)
        persist()
        flush()
    }

    /// Ends the running session and returns its event. Time is counted on the task, never twice.
    private func endSession(complete: Bool, note: String?, workType: String?) -> Event {
        let a = active!
        let secs = Int(activeSeconds().rounded())
        let end = clock.wall
        let task = tasks.first { $0.id == a.taskId }
        if let i = tasks.firstIndex(where: { $0.id == a.taskId }) { tasks[i].totalSeconds += secs }
        active = nil
        return Event(id: shortID("evt"), taskId: a.taskId, type: .session,
                     workDate: Chicago.dateString(a.startedWall), recordedAt: Chicago.iso(end),
                     startedAt: Chicago.iso(a.startedWall), endedAt: Chicago.iso(end),
                     taskText: task?.text ?? "", activeSeconds: secs, timeSource: .measured,
                     complete: complete, workType: workType, note: note)
    }

    // MARK: Completion

    func complete(_ taskId: String, note rawNote: String?, workType rawType: String?) throws {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { throw EngineError.taskNotFound }
        let note = clean(rawNote)
        let type = try cleanWorkType(rawType)
        let ev: Event
        if let a = active, a.taskId == taskId {
            ev = endSession(complete: true, note: note, workType: type)
        } else {
            let now = clock.wall
            ev = Event(id: shortID("evt"), taskId: taskId, type: .completion,
                       workDate: Chicago.dateString(now), recordedAt: Chicago.iso(now),
                       startedAt: nil, endedAt: nil, taskText: tasks[idx].text, activeSeconds: 0,
                       timeSource: .measured, complete: true, workType: type, note: note)
        }
        tasks.removeAll { $0.id == taskId }
        pending.append(ev)
        persist()
        flush()
    }

    // MARK: Retrospective entry

    func logFinished(text rawText: String, date: String, minutes rawMinutes: String, note rawNote: String?,
                     workType rawType: String?, opId: String?) throws {
        if let op = opId, recentOps.contains(op) { return }      // double-click on the same form
        let text = rawText.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw EngineError.emptyTask }
        guard text.count <= 200 else { throw EngineError.taskTooLong }
        guard let day = Chicago.parseDate(date.trimmingCharacters(in: .whitespaces)) else { throw EngineError.invalidDate }
        guard day <= Chicago.dateString(clock.wall) else { throw EngineError.futureDate }
        let type = try cleanWorkType(rawType)
        let m = rawMinutes.trimmingCharacters(in: .whitespaces)
        var secs: Int?
        if !m.isEmpty {
            guard m.range(of: #"^\d+(\.\d+)?$"#, options: .regularExpression) != nil, let v = Double(m), v <= 1440 else {
                throw EngineError.invalidMinutes
            }
            secs = Int((v * 60).rounded())
        }
        let now = clock.wall
        let ev = Event(id: shortID("evt"), taskId: shortID("t"), type: .retrospective, workDate: day,
                       recordedAt: Chicago.iso(now), startedAt: nil, endedAt: nil, taskText: text,
                       activeSeconds: secs, timeSource: secs == nil ? .unknown : .estimated,
                       complete: true, workType: type, note: clean(rawNote))
        if let op = opId { recentOps.append(op); if recentOps.count > 50 { recentOps.removeFirst() } }
        pending.append(ev)
        persist()
        flush()
    }

    private func clean(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    private func cleanWorkType(_ s: String?) throws -> String? {
        guard let s = clean(s) else { return nil }
        guard allowedWorkTypes.contains(s) else { throw EngineError.invalidWorkType }
        return s
    }

    // MARK: Saving

    /// Tries to write pending events in order. Stops at the first failure and keeps everything
    /// that wasn't saved. `acknowledgeExternal` is only true when the user pressed Retry.
    func flush(acknowledgeExternal: Bool = false) {
        while let e = pending.first {
            do {
                try store.append(e, to: logFolder, acknowledgeExternal: acknowledgeExternal)
                pending.removeFirst()
                lastSavedAt = clock.wall
                lastError = nil
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                break
            }
        }
        persist()
    }

    func retry() { flush(acknowledgeExternal: true) }

    func setLogFolder(_ url: URL) {
        logFolder = url
        lastError = nil
        persist()
        if !pending.isEmpty { flush() }
    }

    // MARK: System events

    func systemWillSleep() {
        guard isRunning else { return }
        pause()
        notice = "Paused when your Mac went to sleep. Sleep time isn't counted. Resume when you're back."
        persist()
    }

    func appWillQuit() {
        pause()
        persist()
    }

    // MARK: UI snapshot

    func snapshot() -> [String: Any] {
        let act = Int(activeSeconds().rounded())
        var taskRows: [[String: Any]] = []
        for t in tasks {
            let isActive = active?.taskId == t.id
            taskRows.append(["id": t.id, "text": t.text, "seconds": t.totalSeconds + (isActive ? act : 0)])
        }
        var activeObj: Any = NSNull()
        if let a = active { activeObj = ["taskId": a.taskId, "seconds": act, "running": a.runningSince != nil] }
        let now = clock.wall
        return [
            "tasks": taskRows,
            "active": activeObj,
            "pending": pending.count,
            "error": lastError ?? NSNull(),
            "notice": notice ?? NSNull(),
            "savedAt": lastSavedAt.map { Chicago.timeString($0) } ?? NSNull(),
            "folderName": logFolder.lastPathComponent,
            "folderPath": logFolder.path,
            "today": Chicago.dateString(now),
            "dateLabel": Chicago.label(now),
        ]
    }
}

extension JSONEncoder {
    static var pf: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var pf: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
