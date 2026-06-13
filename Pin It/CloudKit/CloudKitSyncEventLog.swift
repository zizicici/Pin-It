//
//  CloudKitSyncEventLog.swift
//  Pin It
//
//  A bounded, privacy-safe diagnostic log of CloudKit sync events.
//
//  Why this exists: `CloudKitSync.lastError` is a single, deduped, last-write-
//  wins string — the real root cause of a failed run is routinely overwritten by
//  a later harmless result, and a whole class of "harmless but lossy" accepted
//  edge cases never writes an error at all. This log keeps a rolling history of
//  high-level sync events so a user who hits a non-reproducible sync problem can
//  export it from Settings and send it over.
//
//  Storage is a set of rotating plain-text segment files (not one ever-growing
//  file): events append to the newest segment; once it reaches `maxLinesPerFile`
//  a new segment starts, and only the newest `maxFiles` segments are kept. Total
//  size is therefore bounded by maxLinesPerFile * maxFiles lines. Tune those two
//  constants to trade history depth against disk footprint.
//
//  Two correctness rules this component must never break:
//   1. Recording only touches an in-memory buffer. File I/O happens later on a
//      dedicated serial queue, NEVER on a caller's thread mid-sync — so a sync
//      engine transaction is never blocked behind a log write.
//   2. The log never writes to the app database, so it can't trip the
//      `.DatabaseUpdated` notification that drives `databaseDidUpdate → sync()`
//      (which would loop: write log → trigger sync → write log).
//
//  Privacy: messages may only contain identifiers (recordName/syncId are UUIDs),
//  record types, CKError codes, counts, conflict winner side, and timestamps —
//  NEVER post text, image bytes, or style content.
//

import Foundation

enum CloudKitSyncEventLevel: String {
    case info
    case warning
    case error
}

enum CloudKitSyncEventKind: String {
    case runStart
    case runEnd
    case fetched
    case sent
    case fetchedDatabase
    case conflict
    case prune
    case tombstonePurge
    case zoneReset
    case accountChange
    case error
}

struct CloudKitSyncEvent {
    var timestamp: Int64
    var level: CloudKitSyncEventLevel
    var kind: CloudKitSyncEventKind
    var recordType: String?
    var runId: Int64?
    var message: String

    var formattedLine: String {
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1000.0)
        let ts = CloudKitSyncEventLog.lineDateFormatter.string(from: date)
        let levelTag = level.rawValue.uppercased()
        let runTag = runId.map { " #\($0)" } ?? ""
        let typeTag = recordType.map { " [\($0)]" } ?? ""
        // One event is one line: collapse any stray newlines so segment line
        // counts (and the per-line export) stay accurate.
        let safeMessage = message.replacingOccurrences(of: "\n", with: " ")
        return "\(ts) \(levelTag) \(kind.rawValue)\(runTag)\(typeTag): \(safeMessage)"
    }
}

final class CloudKitSyncEventLog: @unchecked Sendable {
    static let shared = CloudKitSyncEventLog()

    /// Rotation thresholds — total stored lines are bounded by their product.
    private static let maxLinesPerFile = 1000
    private static let maxFiles = 10
    /// Force a flush once the in-memory buffer reaches this many events, so a
    /// long burst between debounced flushes can't accumulate unbounded in RAM.
    private static let bufferFlushThreshold = 256

    private static let segmentPrefix = "sync-"
    private static let segmentSuffix = ".log"
    private static let directoryName = "CloudKitDiagnostics"

    static let lineDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private let lock = NSLock()
    private var buffer: [CloudKitSyncEvent] = []
    private let flushQueue = DispatchQueue(label: "com.zizicici.pin.CloudKitSyncEventLog", qos: .utility)

    // The following two are touched ONLY on flushQueue, so they need no lock.
    private var activeSegmentIndex: Int?
    private var activeSegmentLineCount = 0

    private lazy var flushDebounce = Debounce<Int>(duration: 1.5) { [weak self] _ in
        self?.flushQueue.async { self?.drainAndWrite() }
    }

    private init() {
        _ = flushDebounce
    }

    private var logDirectoryURL: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        return base.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    // MARK: - Recording (hot path, in-memory only)

    func record(
        _ kind: CloudKitSyncEventKind,
        level: CloudKitSyncEventLevel = .info,
        recordType: CloudKitRecordType? = nil,
        runId: Int64? = nil,
        _ message: String
    ) {
        let event = CloudKitSyncEvent(
            timestamp: Date().millisecondsSince1970,
            level: level,
            kind: kind,
            recordType: recordType?.rawValue,
            runId: runId,
            message: message
        )

        lock.lock()
        buffer.append(event)
        let shouldFlushNow = buffer.count >= Self.bufferFlushThreshold
        lock.unlock()

        if shouldFlushNow {
            flushQueue.async { [weak self] in self?.drainAndWrite() }
        } else {
            flushDebounce.emit(value: 0)
        }
    }

    // MARK: - Flushing (serial queue, file I/O only)

    /// Drains buffered events to disk synchronously. Call before export and on
    /// background so the most recent events are persisted.
    func flushSynchronously() {
        flushQueue.sync { drainAndWrite() }
    }

    /// Must run on flushQueue.
    private func drainAndWrite() {
        lock.lock()
        let events = buffer
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()

        guard !events.isEmpty, let dir = logDirectoryURL else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try ensureActiveSegmentLoaded(in: dir)

            var lines = events.map { $0.formattedLine }
            while !lines.isEmpty {
                if activeSegmentLineCount >= Self.maxLinesPerFile {
                    rotateSegment()
                }
                let capacity = max(1, Self.maxLinesPerFile - activeSegmentLineCount)
                let chunk = Array(lines.prefix(capacity))
                lines.removeFirst(chunk.count)
                guard let index = activeSegmentIndex else { break }
                try appendLines(chunk, toSegment: index, in: dir)
                activeSegmentLineCount += chunk.count
            }
            pruneOldSegments(in: dir)
        } catch {
            // Diagnostics are best-effort; never disrupt the app for a log write.
            // A throw mid-append can leave the in-memory segment counter out of
            // step with what actually reached disk. Forget it so the next flush
            // re-derives the active segment and its line count from disk rather
            // than trusting a possibly-stale count (which could overfill a file).
            activeSegmentIndex = nil
            activeSegmentLineCount = 0
        }
    }

    /// Must run on flushQueue.
    private func ensureActiveSegmentLoaded(in dir: URL) throws {
        guard activeSegmentIndex == nil else { return }
        let indices = (try? segmentIndices(in: dir)) ?? []
        if let newest = indices.max() {
            activeSegmentIndex = newest
            activeSegmentLineCount = lineCount(ofSegment: newest, in: dir)
        } else {
            activeSegmentIndex = 0
            activeSegmentLineCount = 0
        }
    }

    /// Must run on flushQueue.
    private func rotateSegment() {
        activeSegmentIndex = (activeSegmentIndex ?? -1) + 1
        activeSegmentLineCount = 0
    }

    private func appendLines(_ lines: [String], toSegment index: Int, in dir: URL) throws {
        guard !lines.isEmpty else { return }
        let url = segmentURL(index, in: dir)
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    /// Must run on flushQueue. Keeps only the newest `maxFiles` segments.
    private func pruneOldSegments(in dir: URL) {
        guard let indices = try? segmentIndices(in: dir), indices.count > Self.maxFiles else { return }
        let sorted = indices.sorted()
        for index in sorted.prefix(indices.count - Self.maxFiles) {
            try? FileManager.default.removeItem(at: segmentURL(index, in: dir))
        }
    }

    // MARK: - Segment file helpers

    private func segmentURL(_ index: Int, in dir: URL) -> URL {
        dir.appendingPathComponent(String(format: "%@%06d%@", Self.segmentPrefix, index, Self.segmentSuffix))
    }

    private func segmentIndices(in dir: URL) throws -> [Int] {
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        return names.compactMap { name in
            guard name.hasPrefix(Self.segmentPrefix), name.hasSuffix(Self.segmentSuffix) else { return nil }
            let middle = name.dropFirst(Self.segmentPrefix.count).dropLast(Self.segmentSuffix.count)
            return Int(middle)
        }
    }

    private func lineCount(ofSegment index: Int, in dir: URL) -> Int {
        guard let data = try? Data(contentsOf: segmentURL(index, in: dir)) else { return 0 }
        return data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    // MARK: - Reading / export

    /// Whether there is anything worth exporting (stored segments or buffered events).
    func hasEvents() -> Bool {
        lock.lock()
        let buffered = !buffer.isEmpty
        lock.unlock()
        if buffered { return true }
        guard let dir = logDirectoryURL, let indices = try? segmentIndices(in: dir) else { return false }
        return !indices.isEmpty
    }

    /// Total stored line count and segment file count, for a UI summary.
    func storageSummary() -> (lines: Int, files: Int) {
        var lines = 0
        var files = 0
        flushQueue.sync {
            guard let dir = logDirectoryURL, let indices = try? segmentIndices(in: dir) else { return }
            files = indices.count
            for index in indices {
                lines += lineCount(ofSegment: index, in: dir)
            }
        }
        return (lines, files)
    }

    /// Builds a zip archive containing the caller-supplied (content-free) header
    /// as `info.txt` plus a copy of every stored segment file, and returns its
    /// URL in the temporary directory (nil on failure). Staging the copies runs
    /// on flushQueue so it flushes pending events first and snapshots segments
    /// without racing an append; zipping happens off the queue.
    func exportArchive(header: String) -> URL? {
        let baseName = "PinIt-CloudKit-Diagnostics-\(Self.fileTimestamp())"
        let stagingURL = FileManager.default.temporaryDirectory.appendingPathComponent(baseName, isDirectory: true)

        var staged = false
        flushQueue.sync {
            drainAndWrite()
            guard let dir = logDirectoryURL else { return }
            do {
                if FileManager.default.fileExists(atPath: stagingURL.path) {
                    try FileManager.default.removeItem(at: stagingURL)
                }
                try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
                try Data(header.utf8).write(to: stagingURL.appendingPathComponent("info.txt"))
                for index in ((try? segmentIndices(in: dir)) ?? []).sorted() {
                    let source = segmentURL(index, in: dir)
                    guard FileManager.default.fileExists(atPath: source.path) else { continue }
                    try FileManager.default.copyItem(at: source, to: stagingURL.appendingPathComponent(source.lastPathComponent))
                }
                staged = true
            } catch {
                staged = false
            }
        }
        guard staged else { return nil }

        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent(baseName + ".zip")
        let zipped = Self.zipDirectory(stagingURL, to: zipURL)
        try? FileManager.default.removeItem(at: stagingURL)
        return zipped ? zipURL : nil
    }

    /// Zips a directory using NSFileCoordinator's `.forUploading` option, which
    /// produces a zip of the folder — no third-party dependency.
    private static func zipDirectory(_ directoryURL: URL, to destinationURL: URL) -> Bool {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var success = false
        coordinator.coordinate(readingItemAt: directoryURL, options: [.forUploading], error: &coordinatorError) { zippedURL in
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: zippedURL, to: destinationURL)
                success = true
            } catch {
                success = false
            }
        }
        return success && coordinatorError == nil
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    func clear() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
        flushQueue.sync {
            if let dir = logDirectoryURL, let indices = try? segmentIndices(in: dir) {
                for index in indices {
                    try? FileManager.default.removeItem(at: segmentURL(index, in: dir))
                }
            }
            activeSegmentIndex = nil
            activeSegmentLineCount = 0
        }
    }
}
