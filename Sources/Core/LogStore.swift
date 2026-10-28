import Foundation

enum LogError: Error, LocalizedError {
    case destinationMissing(String)
    case notWritable(String)
    case conflict(String)
    case io(String)
    case verifyFailed(String)

    var errorDescription: String? {
        switch self {
        case .destinationMissing(let p): return "The log folder doesn't exist: \(p). Choose a folder, then retry."
        case .notWritable(let p): return "The log folder isn't writable: \(p). Fix its permissions or choose another folder, then retry."
        case .conflict(let m): return "The log file changed outside the app (\(m)). Nothing was overwritten. Retry to continue."
        case .io(let m): return "Couldn't save (\(m)). Retry."
        case .verifyFailed(let m): return "Couldn't confirm the save (\(m)). Retry to check."
        }
    }
}

enum Fault { case none, failBeforeWrite, failAfterWrite }

/// Appends one Markdown block per event to `<folder>/<work date>.md`.
///
/// Rules this type enforces:
/// - It only ever appends. It never rewrites, truncates or repairs an existing file.
/// - Writes are serialized on one queue and guarded by an exclusive file lock.
/// - It re-reads the file first. If the event id is already there (a retry after an ambiguous
///   failure) it reports success without writing again.
/// - If earlier content changed since this app last wrote the file, it refuses to append until
///   the user retries (`acknowledgeExternal`).
/// - A save is only reported as done after the file is read back and checked.
final class LogStore {
    private let queue = DispatchQueue(label: "personal-focus.logstore")
    private var known: [String: (len: Int, hash: String)] = [:]

    // Test hooks. Production code leaves these alone.
    var fault: Fault = .none
    var hookAfterRead: (() -> Void)?
    var hookAfterWrite: ((URL) -> Void)?

    func append(_ event: Event, to folder: URL, acknowledgeExternal: Bool) throws {
        try queue.sync {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
                throw LogError.destinationMissing(folder.path)
            }
            let url = folder.appendingPathComponent("\(event.workDate).md")
            let path = url.path

            var existing: Data?
            if fm.fileExists(atPath: path) {
                guard let d = fm.contents(atPath: path) else { throw LogError.notWritable(path) }
                existing = d
            }
            hookAfterRead?()

            let block = Data((event.markdown() + "\n").utf8)

            if let ex = existing, containsLine(ex, Event.eventLine(event.id)) {
                guard ex.range(of: block) != nil else {
                    throw LogError.conflict("this event's record is incomplete; not adding a second copy")
                }
                known[path] = (ex.count, sha256Hex(ex))
                return
            }

            if let k = known[path], !acknowledgeExternal {
                guard let ex = existing else { throw LogError.conflict("the file was removed") }
                if ex.count < k.len || sha256Hex(Data(ex.prefix(k.len))) != k.hash {
                    throw LogError.conflict("earlier content was edited")
                }
            }

            var out = Data()
            if let ex = existing, !ex.isEmpty {
                if ex.last != 0x0A { out.append(Data("\n\n".utf8)) }
                else if !ex.suffix(2).elementsEqual(Data("\n\n".utf8)) { out.append(Data("\n".utf8)) }
            } else {
                out.append(Data("# Work log \(event.workDate)\n\n".utf8))
            }
            out.append(block)

            if fault == .failBeforeWrite { throw LogError.io("simulated failure before writing") }

            let flags = (existing == nil) ? (O_WRONLY | O_APPEND | O_CREAT | O_EXCL) : (O_WRONLY | O_APPEND)
            let fd = open(path, flags, 0o644)
            if fd < 0 {
                switch errno {
                case EACCES, EPERM, EROFS: throw LogError.notWritable(folder.path)
                case ENOENT: throw LogError.destinationMissing(folder.path)
                case EEXIST: throw LogError.conflict("a file with this name appeared while saving")
                default: throw LogError.io(String(cString: strerror(errno)))
                }
            }
            defer { close(fd) }
            if flock(fd, LOCK_EX | LOCK_NB) != 0 { throw LogError.conflict("the file is locked by another process") }
            var st = stat()
            fstat(fd, &st)
            if Int(st.st_size) != (existing?.count ?? 0) { throw LogError.conflict("it changed while saving") }

            let written = out.withUnsafeBytes { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                return write(fd, base, buf.count)
            }
            if written != out.count { throw LogError.io("the write was incomplete") }
            fsync(fd)

            if fault == .failAfterWrite { throw LogError.io("simulated interruption after writing") }
            hookAfterWrite?(url)

            guard let after = fm.contents(atPath: path) else { throw LogError.verifyFailed("couldn't read the file back") }
            let prefixOK = existing.map { after.count >= $0.count && Data(after.prefix($0.count)) == $0 } ?? true
            guard prefixOK, after.suffix(block.count).elementsEqual(block) else {
                throw LogError.verifyFailed("the file doesn't match what was written")
            }
            known[path] = (after.count, sha256Hex(after))
        }
    }

    private func containsLine(_ data: Data, _ line: String) -> Bool {
        String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).contains { $0 == Substring(line) }
    }
}
