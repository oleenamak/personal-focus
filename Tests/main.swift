import Foundation

// Minimal test runner. Everything runs in disposable folders under the system temp directory.
// Nothing here touches the real log folder or the real recovery file.

var passed = 0
var failed = 0
var currentGroup = ""

func group(_ name: String) { currentGroup = name; print("\n\(name)") }
func check(_ cond: @autoclosure () -> Bool, _ msg: String, file: StaticString = #file, line: UInt = #line) {
    if cond() { passed += 1; print("  PASS  \(msg)") }
    else { failed += 1; print("  FAIL  \(msg)   [\(line)]") }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("pf-tests-\(UUID().uuidString.prefix(8))")
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

struct Env {
    let clock: TestClock
    let dir: URL
    let logs: URL
    let state: URL
    let engine: Engine
    var store: LogStore { engine.store }
}

func makeEnv(_ name: String, wall: Date = Chicago.make(2026, 10, 28, 10, 0, 0), createLogs: Bool = true) -> Env {
    let dir = root.appendingPathComponent(name)
    let logs = dir.appendingPathComponent("logs")
    let state = dir.appendingPathComponent("state/state.json")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if createLogs { try! FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true) }
    let clock = TestClock(wall: wall)
    return Env(clock: clock, dir: dir, logs: logs, state: state,
               engine: Engine(clock: clock, stateURL: state, defaultFolder: logs))
}

func restart(_ e: Env, advanceWall: TimeInterval = 0) -> Engine {
    e.clock.advanceWallOnly(advanceWall)
    return Engine(clock: e.clock, stateURL: e.state, defaultFolder: e.logs, store: LogStore())
}

func logText(_ e: Env, _ date: String = "2026-10-28") -> String {
    (try? String(contentsOf: e.logs.appendingPathComponent("\(date).md"), encoding: .utf8)) ?? ""
}
func count(_ haystack: String, _ needle: String) -> Int { haystack.components(separatedBy: needle).count - 1 }
func eventIDs(_ s: String) -> [String] {
    s.split(separator: "\n").filter { $0.hasPrefix("- event: evt-") && !$0.contains("(") }.map { String($0.dropFirst(9)) }
}
func fixture() -> Data {
    let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "fixtures/2026-10-28.md"
    return FileManager.default.contents(atPath: path) ?? Data()
}

// 1. Paused time is excluded
group("1. Paused-time exclusion (controlled clock)")
do {
    let e = makeEnv("t1"); let en = e.engine
    let t = try! en.addTask("Write the memo")
    try! en.start(t.id)
    e.clock.advance(60); en.pause()
    e.clock.advance(120); en.resume()
    e.clock.advance(30)
    let snap = en.snapshot()["active"] as? [String: Any]
    check((snap?["seconds"] as? Int) == 90, "UI snapshot shows 90 active seconds before stop")
    try! en.stop()
    let log = logText(e)
    check(log.contains("- active seconds: 90"), "saved event has 90 active seconds")
    check(log.contains("- complete: no"), "saved event is incomplete")
    check(log.contains("- time source: measured"), "time source is measured")
    check(en.pending.isEmpty && en.lastError == nil, "event saved and verified, nothing pending")
    e.clock.advance(900)
    check(count(logText(e), "- event: evt-") == 1, "time after stop adds nothing")
    check(en.tasks.first?.totalSeconds == 90, "task keeps 90 total seconds")
}

// 2. Sleep / suspended time
group("2. Suspended and stopped time add nothing")
do {
    let e = makeEnv("t2"); let en = e.engine
    let t = try! en.addTask("Review agent output")
    try! en.start(t.id)
    e.clock.advance(100)
    en.systemWillSleep()
    check(!en.isRunning, "sleep pauses the timer")
    e.clock.advanceWallOnly(3600)
    check(Int(en.activeSeconds().rounded()) == 100, "an hour asleep adds nothing (still 100)")
    check(en.notice?.contains("sleep") == true, "user is told sleep time wasn't counted")
    en.resume(); e.clock.advance(20); try! en.stop()
    check(logText(e).contains("- active seconds: 120"), "after resume only 20 more seconds count")
}

// 3. Stop vs completion
group("3. Stop versus completion")
do {
    let e = makeEnv("t3"); let en = e.engine
    let t = try! en.addTask("Draft proposal")
    try! en.start(t.id); e.clock.advance(300); try! en.stop()
    check(en.tasks.contains { $0.id == t.id }, "Stop keeps the task on the page")
    check(logText(e).contains("- complete: no"), "Stop saves an incomplete session")
    try! en.start(t.id); e.clock.advance(120); try! en.stop()
    let ids = eventIDs(logText(e))
    check(ids.count == 2 && Set(ids).count == 2, "second session on the same task is a separate event")
    try! en.complete(t.id, note: nil, workType: nil)
    let log = logText(e)
    check(count(log, "- complete: yes") == 1, "completing after Stop appends one completion event")
    check(log.contains("- type: completion") && log.contains("- active seconds: 0"), "completion adds zero seconds")
    check(raises { try en.complete(t.id, note: nil, workType: nil) }, "second completion click is a no-op")
    check(eventIDs(logText(e)).count == 3, "still exactly 3 events")

    let u = try! en.addTask("Run while completing")
    try! en.start(u.id); e.clock.advance(75)
    try! en.complete(u.id, note: "Finished it", workType: "Planning")
    let log2 = logText(e)
    check(log2.contains("- active seconds: 75") && log2.contains("- type: session"), "completing while running logs the session once")
    check(count(log2, "- note: Finished it") == 1 && !en.hasActive, "session ended and logged exactly once")
    check(en.tasks.isEmpty, "completed tasks leave the page")
}

// 4. Retrospective
group("4. Retrospective logging")
do {
    let e = makeEnv("t4"); let en = e.engine
    try! en.logFinished(text: "Sent the invoice", date: "2026-10-20", minutes: "12", note: nil, workType: nil, opId: "a")
    try! en.logFinished(text: "Called the bank", date: "2026-10-20", minutes: "", note: "Quick one", workType: "Independent work", opId: "b")
    try! en.logFinished(text: "Zero minute task", date: "2026-10-20", minutes: "0", note: nil, workType: nil, opId: "c")
    let log = logText(e, "2026-10-20")
    check(log.contains("- active seconds: 720") && log.contains("- time source: estimated"), "12 minutes becomes 720 estimated seconds")
    check(log.contains("- active seconds: unknown") && log.contains("- time source: unknown"), "blank becomes unknown")
    check(log.contains("- active seconds: 0\n- active time: 0s\n- time source: estimated"), "explicit zero stays zero")
    check(count(log, "- complete: yes") == 3, "all three are complete")
    check(!en.tasks.contains { _ in true } && !en.hasActive, "no timer was started")
    let before = logText(e, "2026-10-20")
    for bad in ["-5", "abc", "1e3", "12 min", "NaN", "1441", "--3"] {
        check(raises { try en.logFinished(text: "x", date: "2026-10-20", minutes: bad, note: nil, workType: nil, opId: nil) }, "rejects minutes \"\(bad)\"")
    }
    check(raises { try en.logFinished(text: "x", date: "2026-02-31", minutes: "5", note: nil, workType: nil, opId: nil) }, "rejects an impossible date")
    check(raises { try en.logFinished(text: "x", date: "2026-11-30", minutes: "5", note: nil, workType: nil, opId: nil) }, "rejects a future date")
    check(raises { try en.logFinished(text: "x", date: "2026-10-20", minutes: "5", note: nil, workType: "Shopping", opId: nil) }, "rejects an unknown work type")
    check(raises { try en.logFinished(text: "  ", date: "2026-10-20", minutes: "5", note: nil, workType: nil, opId: nil) }, "rejects empty task text")
    check(logText(e, "2026-10-20") == before && en.pending.isEmpty, "invalid entries append nothing")
    check(FileManager.default.fileExists(atPath: e.logs.appendingPathComponent("2026-10-20.md").path) && logText(e).isEmpty, "entry went to the chosen date's file, not today's")
}

// 5. Six-feature walkthrough
group("5. Six-feature walkthrough")
do {
    let e = makeEnv("t5"); let en = e.engine
    let t = try! en.addTask("Outline this week's article")
    try! en.start(t.id); e.clock.advance(1500); en.pause(); e.clock.advance(60); en.resume(); e.clock.advance(300)
    try! en.stop()
    try! en.complete(t.id, note: "Outline done,\nready to draft", workType: "Independent work")
    try! en.logFinished(text: "Booked hair appointment", date: "2026-10-28", minutes: "5", note: nil, workType: nil, opId: "w")
    let log = logText(e)
    check(log.contains("- task: Outline this week's article"), "task text saved")
    check(log.contains("- active seconds: 1800"), "measured time excludes the pause (1500+300)")
    check(log.contains("- work type: Independent work"), "work type saved when chosen")
    check(log.contains("- note:\n  > Outline done,\n  > ready to draft"), "multi-line note saved safely")
    check(log.contains("- task: Booked hair appointment") && !logSection(log, "Booked hair").contains("work type"), "optional fields can be absent")
    check(log.contains("# Work log 2026-10-28"), "new daily file gets a heading")
    try? FileManager.default.createDirectory(atPath: "sample-output", withIntermediateDirectories: true)
    try? log.write(toFile: "sample-output/2026-10-28.md", atomically: true, encoding: .utf8)
}
func logSection(_ log: String, _ needle: String) -> String {
    log.components(separatedBy: "### ").first { $0.contains(needle) } ?? ""
}

// 6. Safe appends
group("6. Safe appends against a messy existing file")
do {
    let e = makeEnv("t6"); let en = e.engine
    let original = fixture()
    check(!original.isEmpty, "fixture loaded")
    try! original.write(to: e.logs.appendingPathComponent("2026-10-28.md"))
    let t = try! en.addTask("Plan\nthe week")
    try! en.start(t.id); e.clock.advance(10); try! en.stop()
    let tricky = "# Heading in a note\n- event: evt-fake00001\n---\n`code` <tag> & \"quotes\" 🙂 Ünï"
    try! en.complete(t.id, note: tricky, workType: nil)
    try! en.logFinished(text: "Retro", date: "2026-10-28", minutes: "3", note: nil, workType: nil, opId: "same")
    try! en.logFinished(text: "Retro", date: "2026-10-28", minutes: "3", note: nil, workType: nil, opId: "same")
    let after = try! Data(contentsOf: e.logs.appendingPathComponent("2026-10-28.md"))
    check(Data(after.prefix(original.count)) == original, "existing content is unchanged, byte for byte")
    let text = String(decoding: after, as: UTF8.self)
    let ids = eventIDs(text)
    check(ids.count == 3 && Set(ids).count == 3, "3 events, every id exactly once")
    check(count(text, "- event: evt-fake00001") == 0 || text.contains("  > - event: evt-fake00001"), "a note can't forge an event line")
    check(text.contains("  > # Heading in a note") && text.contains("  > `code` <tag> & \"quotes\" 🙂 Ünï"), "special characters preserved inside a quote")
    check(text.contains("- task: Plan the week"), "a typed newline in a task is flattened to one line")
    let multi = Event(id: "evt-multi0001", taskId: "t-m", type: .completion, workDate: "2026-10-28", recordedAt: "2026-10-28T10:00:00-05:00",
                      startedAt: nil, endedAt: nil, taskText: "line one\n# not a heading\n- event: evt-forged", activeSeconds: 0,
                      timeSource: .measured, complete: true, workType: nil, note: nil).markdown()
    check(multi.contains("- task:\n  > line one\n  > # not a heading\n  > - event: evt-forged") && !multi.contains("\n- event: evt-forged"), "multi-line task text is quoted and can't forge structure")
    check(en.pending.isEmpty, "everything verified saved")

    // Ambiguous failure: written, but the app is told it failed
    en.store.fault = .failAfterWrite
    try! en.logFinished(text: "Ambiguous save", date: "2026-10-28", minutes: "1", note: nil, workType: nil, opId: "amb")
    check(en.pending.count == 1 && en.lastError != nil, "ambiguous failure keeps the event pending and visible")
    check(count(logText(e), "Ambiguous save") >= 1, "(the block really did reach the file)")
    en.store.fault = .none
    en.flush()
    check(count(logText(e), "- task: Ambiguous save") == 1 && en.pending.isEmpty, "retry with the same id doesn't duplicate")
    check(eventIDs(logText(e)).count == 4, "now 4 events, no duplicates")

    // Concurrent writers
    let store = LogStore()
    let folder = e.dir.appendingPathComponent("concurrent"); try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let g = DispatchGroup()
    for i in 0..<8 {
        DispatchQueue.global().async(group: g) {
            for j in 0..<10 {
                let ev = Event(id: "evt-c\(i)x\(j)", taskId: "t-c", type: .retrospective, workDate: "2026-10-28",
                               recordedAt: "2026-10-28T10:00:00-05:00", startedAt: nil, endedAt: nil,
                               taskText: "c\(i)-\(j)", activeSeconds: 1, timeSource: .estimated, complete: true, workType: nil, note: nil)
                var done = false
                while !done { do { try store.append(ev, to: folder, acknowledgeExternal: true); done = true } catch { usleep(1000) } }
            }
        }
    }
    g.wait()
    let c = (try? String(contentsOf: folder.appendingPathComponent("2026-10-28.md"), encoding: .utf8)) ?? ""
    check(eventIDs(c).count == 80 && Set(eventIDs(c)).count == 80, "80 concurrent appends: each id exactly once")
}

// 6b. External changes
group("6b. External-change detection")
do {
    let e = makeEnv("t6b"); let en = e.engine
    try! fixture().write(to: e.logs.appendingPathComponent("2026-10-28.md"))
    try! en.logFinished(text: "First", date: "2026-10-28", minutes: "1", note: nil, workType: nil, opId: "1")
    let file = e.logs.appendingPathComponent("2026-10-28.md")

    // Appending outside the app (e.g. typing at the bottom in Obsidian) is safe
    var s = try! String(contentsOf: file, encoding: .utf8); s += "\nA line I typed in Obsidian.\n"
    try! s.write(to: file, atomically: true, encoding: .utf8)
    try! en.logFinished(text: "Second", date: "2026-10-28", minutes: "1", note: nil, workType: nil, opId: "2")
    check(en.pending.isEmpty && logText(e).contains("A line I typed in Obsidian.") && logText(e).contains("- task: Second"), "external append is fine and both survive")

    // Editing earlier text is a conflict
    var edited = try! String(contentsOf: file, encoding: .utf8)
    edited = edited.replacingOccurrences(of: "Unrelated text", with: "Edited text")
    try! edited.write(to: file, atomically: true, encoding: .utf8)
    let beforeConflict = try! Data(contentsOf: file)
    try! en.logFinished(text: "Third", date: "2026-10-28", minutes: "1", note: "keep me", workType: nil, opId: "3")
    check(en.pending.count == 1 && en.lastError?.contains("changed outside") == true, "edit of earlier content: nothing appended, event kept pending")
    check(try! Data(contentsOf: file) == beforeConflict, "file left exactly as the user edited it")
    en.retry()
    let final = logText(e)
    check(en.pending.isEmpty && final.contains("Edited text") && final.contains("- task: Third") && final.contains("keep me"), "Retry appends; user's edit and pending data both preserved")

    // Change during the save itself
    let e2 = makeEnv("t6c"); let en2 = e2.engine
    try! fixture().write(to: e2.logs.appendingPathComponent("2026-10-28.md"))
    en2.store.hookAfterRead = { try? "sneaky\n".write(to: e2.logs.appendingPathComponent("2026-10-28.md"), atomically: false, encoding: .utf8) }
    try! en2.logFinished(text: "Racy", date: "2026-10-28", minutes: "1", note: nil, workType: nil, opId: "r")
    check(en2.pending.count == 1 && !logText(e2).contains("Racy"), "change between read and write is caught; nothing appended")
    en2.store.hookAfterRead = nil
    en2.retry()
    check(en2.pending.isEmpty && logText(e2).contains("sneaky") && logText(e2).contains("- task: Racy"), "retry then succeeds and keeps the other writer's text")

    // Verification failure is not reported as saved
    let e3 = makeEnv("t6d"); let en3 = e3.engine
    en3.store.hookAfterWrite = { url in try? Data().write(to: url) }
    try! en3.logFinished(text: "Truncated after write", date: "2026-10-28", minutes: "1", note: nil, workType: nil, opId: "v")
    check(en3.pending.count == 1 && en3.lastError?.contains("confirm") == true && en3.lastSavedAt == nil, "unverifiable save is not claimed as saved")
}

// 7. Failure and recovery
group("7. Failure and recovery")
do {
    let e = makeEnv("t7", createLogs: false); let en = e.engine
    try! en.logFinished(text: "Missing folder", date: "2026-10-28", minutes: "2", note: nil, workType: nil, opId: "m")
    check(en.pending.count == 1 && en.lastError?.contains("doesn't exist") == true, "missing destination: unsaved state and a clear error")
    check((en.snapshot()["pending"] as? Int) == 1, "UI snapshot reports 1 unsaved")
    try! FileManager.default.createDirectory(at: e.logs, withIntermediateDirectories: true)
    en.retry()
    check(en.pending.isEmpty && count(logText(e), "- task: Missing folder") == 1, "after the folder exists, retry saves it once")

    try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: e.logs.path)
    try! en.logFinished(text: "Locked folder", date: "2026-10-27", minutes: "2", note: nil, workType: nil, opId: "l")
    check(en.pending.count == 1 && en.lastError?.contains("isn't writable") == true, "unwritable destination: kept pending with a clear error")
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: e.logs.path)
    en.retry()
    check(en.pending.isEmpty && logText(e, "2026-10-27").contains("- task: Locked folder"), "after fixing permissions, retry saves")

    en.store.fault = .failBeforeWrite
    try! en.logFinished(text: "Interrupted", date: "2026-10-28", minutes: "2", note: nil, workType: nil, opId: "i")
    check(en.pending.count == 1 && !logText(e).contains("Interrupted"), "interrupted save: nothing written, still pending")
    en.store.fault = .none; en.retry()
    check(en.pending.isEmpty && count(logText(e), "- task: Interrupted") == 1, "retry saves it once")

    // Pending events survive a restart
    let e2 = makeEnv("t7b", createLogs: false); let en2 = e2.engine
    try! en2.logFinished(text: "Survives restart", date: "2026-10-28", minutes: "4", note: nil, workType: nil, opId: "s")
    let evId = en2.pending[0].id
    let reopened = restart(e2)
    check(reopened.pending.count == 1 && reopened.pending[0].id == evId, "pending event (same id) is restored after restart")
    try! FileManager.default.createDirectory(at: e2.logs, withIntermediateDirectories: true)
    reopened.flush()
    check(reopened.pending.isEmpty && logText(e2).contains(evId), "and saves after restart")

    // Corrupt recovery file
    let e3 = makeEnv("t7c")
    try! FileManager.default.createDirectory(at: e3.state.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! "{ not json".write(to: e3.state, atomically: true, encoding: .utf8)
    let corrupt = restart(e3)
    let kept = (try? FileManager.default.contentsOfDirectory(atPath: e3.state.deletingLastPathComponent().path))?.filter { $0.hasPrefix("state.unreadable") } ?? []
    check(corrupt.tasks.isEmpty && corrupt.notice != nil && kept.count == 1, "unreadable recovery file is kept aside, not silently discarded")
}

// 8. Restart / crash / downtime
group("8. Restart and checkpoint recovery")
do {
    let e = makeEnv("t8"); let en = e.engine
    let t = try! en.addTask("Long task")
    try! en.start(t.id)
    let writesBefore = en.persistCount
    for _ in 0..<62 { e.clock.advance(1); en.tick() }
    let writes = en.persistCount - writesBefore
    check(writes >= 11 && writes <= 13, "checkpoints at most every 5s (\(writes) writes in 62s)")
    e.clock.advance(3)                                  // work after the last checkpoint, then a crash
    let lastCheckpointSecs = 60
    let reopened = restart(e, advanceWall: 3600)        // an hour of downtime
    check(!reopened.isRunning && reopened.hasActive, "after an unexpected quit the timer comes back paused")
    let recovered = Int(reopened.activeSeconds().rounded())
    check(recovered >= lastCheckpointSecs && recovered <= 63, "recovered at the checkpoint (\(recovered)s), not the full downtime")
    check(reopened.notice?.contains("unexpectedly") == true && reopened.notice?.contains("may be missing") == true, "the possible gap is disclosed")
    check(Int(reopened.activeSeconds().rounded()) < 3600, "downtime is never counted")
}
group("8b. Clean quit loses nothing")
do {
    let e = makeEnv("t8b"); let en = e.engine
    let t = try! en.addTask("Quit cleanly")
    try! en.start(t.id); e.clock.advance(47)
    en.appWillQuit()
    let reopened = restart(e, advanceWall: 7200)
    check(Int(reopened.activeSeconds().rounded()) == 47, "exactly 47s after clean quit and 2h away")
    check(reopened.notice?.contains("paused when the app closed") == true && reopened.notice?.contains("missing") == false, "no loss warning after a clean quit")
    reopened.resume(); e.clock.advance(13); try! reopened.stop()
    check(logText(e).contains("- active seconds: 60"), "resuming and stopping logs 60s")
}

// 9. Midnight, dates and offsets
group("9. Date attribution (America/Chicago)")
do {
    let e = makeEnv("t9", wall: Chicago.make(2026, 10, 28, 23, 50, 0)); let en = e.engine
    let t = try! en.addTask("Late night work")
    try! en.start(t.id); e.clock.advance(30 * 60); try! en.stop()
    let log = logText(e, "2026-10-28")
    check(log.contains("- work date: 2026-10-28") && log.contains("- started: 2026-10-28T23:50:00-05:00"), "session crossing midnight is attributed to its start date")
    check(log.contains("- ended: 2026-10-29T00:20:00-05:00") && logText(e, "2026-10-29").isEmpty, "...and written to the start day's file only")
    check(log.contains("- active seconds: 1800"), "full 30 minutes counted")

    let d = makeEnv("t9b", wall: Chicago.make(2026, 11, 2, 12, 0, 0))
    try! d.engine.logFinished(text: "After DST ends", date: "2026-11-01", minutes: "1", note: nil, workType: nil, opId: nil)
    check(logText(d, "2026-11-01").contains("recorded: 2026-11-02T12:00:00-06:00"), "offset is -06:00 after DST ends")
    check(Chicago.iso(Chicago.make(2026, 10, 28, 10, 0, 0)).hasSuffix("-05:00"), "offset is -05:00 before DST ends")
}

// 10. The "done today" list on the note
group("10. Done today list")
do {
    let e = makeEnv("t10"); let en = e.engine
    func doneTexts(_ x: Engine) -> [String] { (x.snapshot()["done"] as! [[String: Any]]).map { $0["text"] as! String } }
    let t = try! en.addTask("Write brief")
    try! en.start(t.id); e.clock.advance(90); try! en.complete(t.id, note: "Shipped", workType: nil)
    let first = (en.snapshot()["done"] as! [[String: Any]]).first
    check(doneTexts(en) == ["Write brief"] && first?["seconds"] as? Int == 90 && first?["note"] as? String == "Shipped", "a finished task shows with its time and note")
    try! en.logFinished(text: "Earlier call", date: "2026-10-28", minutes: "5", note: nil, workType: nil, opId: nil)
    try! en.logFinished(text: "Yesterday's thing", date: "2026-10-27", minutes: "5", note: nil, workType: nil, opId: nil)
    check(doneTexts(en) == ["Write brief", "Earlier call"], "a finished-task entry for today shows; one for another day does not")
    check(doneTexts(restart(e)) == ["Write brief", "Earlier call"], "the list survives a restart")
    check(doneTexts(restart(e, advanceWall: 24 * 3600)).isEmpty, "the list is empty the next day")
}

print("\n\(passed) passed, \(failed) failed")
try? FileManager.default.removeItem(at: root)
exit(failed == 0 ? 0 : 1)

func raises(_ f: () throws -> Void) -> Bool { do { try f(); return false } catch { return true } }
