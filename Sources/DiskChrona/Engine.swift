import Combine
import CoreServices
import Foundation

// MARK: - Path & file helpers

struct Stat {
    let dev, ino, size, alloc, nlink: Int64
    let mtime: Double
    var sizes: (Int64, Int64) { (size, alloc) }

    init(_ s: stat) {
        dev = Int64(s.st_dev)
        ino = Int64(bitPattern: s.st_ino)
        size = Int64(s.st_size)
        alloc = Int64(s.st_blocks) * 512
        nlink = Int64(s.st_nlink)
        mtime = Double(s.st_mtimespec.tv_sec) + Double(s.st_mtimespec.tv_nsec) / 1e9
    }
}

enum Obs { case file(Stat), gone, unknown }

/// lstat only; never reads content. Permission errors are `.unknown`, never `.gone`.
func observe(_ path: String) -> Obs {
    var s = stat()
    guard lstat(path, &s) == 0 else { return errno == ENOENT || errno == ENOTDIR ? .gone : .unknown }
    return s.st_mode & S_IFMT == S_IFREG ? .file(Stat(s)) : .gone
}

func isUnder(_ path: String, _ dir: String) -> Bool {
    path == dir || path.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/")
}

/// Half-open string range matching every path strictly inside `dir` ('0' sorts right after '/').
func prefixRange(_ dir: String) -> (String, String) {
    let lo = dir.hasSuffix("/") ? dir : dir + "/"
    return (lo, String(lo.dropLast()) + "0")
}

func canonical(_ path: String) -> String {
    guard let r = realpath(path, nil) else { return path }
    defer { free(r) }
    return String(cString: r)
}

/// Normalize known aliases as text so historical, already-deleted files keep their classification.
func normalizedSystemPath(_ p: String) -> String {
    var path = p
    let dataVolume = "/System/Volumes/Data"
    if path.hasPrefix(dataVolume + "/") { path = String(path.dropFirst(dataVolume.count)) }
    if isUnder(path, "/var") { path = "/private" + path }
    return path
}

func isSwapFile(_ p: String) -> Bool {
    let path = normalizedSystemPath(p)
    guard let prefix = ["/System/Volumes/VM/swapfile", "/private/var/vm/swapfile"].first(where: { path.hasPrefix($0) }) else { return false }
    let number = path.dropFirst(prefix.count)
    return !number.isEmpty && number.allSatisfy { $0 >= "0" && $0 <= "9" }
}

/// Parts of `range` not covered by any monitoring session.
func coverageGaps(_ range: DateInterval, _ sessions: [DateInterval]) -> [DateInterval] {
    var gaps: [DateInterval] = []
    var cursor = range.start
    for s in sessions.sorted(by: { $0.start < $1.start }) where s.end > cursor {
        if cursor >= range.end { break }
        if s.start > cursor + 1 { gaps.append(DateInterval(start: cursor, end: min(s.start, range.end))) }
        cursor = max(cursor, s.end)
    }
    if cursor < range.end - 1 { gaps.append(DateInterval(start: cursor, end: range.end)) }
    return gaps
}

private func has(_ flags: UInt32, _ mask: Int) -> Bool { flags & UInt32(mask) != 0 }

/// Streams regular files under a directory without following symlinks or crossing mount points.
final class Walker {
    private var fts: UnsafeMutablePointer<FTS>?
    private let skip: (String) -> Bool

    init(_ root: String, skip: @escaping (String) -> Bool) {
        self.skip = skip
        let c = strdup(root)
        var argv: [UnsafeMutablePointer<CChar>?] = [c, nil]
        fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil)
        free(c)
    }

    deinit { if let fts { fts_close(fts) } }

    /// Up to `max` files; nil once exhausted.
    func next(_ max: Int) -> [(String, Stat)]? {
        guard let f = fts else { return nil }
        var out: [(String, Stat)] = []
        while out.count < max {
            guard let e = fts_read(f) else { fts_close(f); fts = nil; break }
            let ent = e.pointee
            let path = String(cString: ent.fts_path)
            switch Int32(ent.fts_info) {
            case FTS_D: if ent.fts_level > 0 && skip(path) { fts_set(f, e, FTS_SKIP) }
            case FTS_F: out.append((path, Stat(ent.fts_statp.pointee)))
            default: break
            }
        }
        return out.isEmpty && fts == nil ? nil : out
    }
}

// MARK: - Engine

struct RootState {
    var unreadable: [String] = []
    var problem: String?
}

struct EngineStatus {
    var roots: [Root] = []
    var states: [Int64: RootState] = [:]
    var paused = false
    var backlog = 0
    var rescanning = false
    var limited: String?
    var warning: String?
    var confirmedAt: Date?
    var sessionStart: Date?
    var dataBytes: Int64 = 0
    var earliest: Date?
    var volumeFree: Int64?
    var revision = 0

    var hasProblem: Bool { states.values.contains { $0.problem != nil || !$0.unreadable.isEmpty } }
    var isHealthy: Bool { limited == nil && !paused && !roots.isEmpty && !hasProblem }
    var symbol: String { limited != nil ? "exclamationmark.octagon" : paused ? "pause.circle" : isHealthy ? "checkmark.circle" : "clock.arrow.circlepath" }

    var summary: String {
        if limited != nil { return "Recording limited" }
        if paused { return "Paused" }
        if roots.isEmpty { return "Starting" }
        if rescanning || backlog > 0 { return "Catching up" + (backlog > 0 ? " (\(backlog) queued)" : "") }
        if hasProblem { return "Partial coverage" }
        return "Monitoring"
    }

    func rootStatus(_ r: Root) -> String {
        let s = states[r.id] ?? RootState()
        if paused { return "Paused" }
        if let p = s.problem { return p }
        if rescanning || backlog > 0 { return "Catching up" }
        return s.unreadable.isEmpty ? "OK" : "Partial coverage"
    }
}

/// Re-checks known files under a directory after coalesced, dropped or overflowing events.
private final class Job {
    let dir: String
    /// Walk the directory too, to find known files that arrived with a directory rename.
    let walk: Bool
    let started = Date().timeIntervalSince1970
    var walker: Walker?
    /// Non-nil once walking is done and rows not seen during the walk are being re-checked.
    var cursor: String?

    init(_ dir: String, walk: Bool) { self.dir = dir; self.walk = walk }
}

/// Net bytes observed in the last 60 seconds: one slot per second, stamped so stale slots read as zero.
struct RateMeter {
    private var slots = [Int64](repeating: 0, count: 60)
    private var swapSlots = [Int64](repeating: 0, count: 60)
    private var stamps = [Int](repeating: -1, count: 60)

    mutating func add(_ delta: Int64, at t: Double, isSwap: Bool = false) {
        let s = Int(t), i = s % 60
        if stamps[i] != s { stamps[i] = s; slots[i] = 0; swapSlots[i] = 0 }
        slots[i] += delta
        if isSwap { swapSlots[i] += delta }
    }

    func sum(at t: Double, ignoreSwap: Bool = false) -> Int64 {
        let s = Int(t)
        return (0..<60).reduce(0) { stamps[$1] > s - 60 ? $0 + slots[$1] - (ignoreSwap ? swapSlots[$1] : 0) : $0 }
    }
}

/// A change waiting for the next flush. Size changes of one path fold into a single row per flush.
private struct Pending {
    var kind: Kind
    let path: String
    let other: String?
    var prev: Double
    let old: (Int64, Int64)
    var new: (Int64, Int64)
    var ts: Double
    let seen: Bool   // began as a first observation
    var foldable: Bool { [.grew, .shrank, .firstSeen, .added].contains(kind) }
    var empty: Bool { (kind == .grew || kind == .shrank) && old == new }
}

private let eventCallback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
    let engine = Unmanaged<Engine>.fromOpaque(info!).takeUnretainedValue()
    let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
    engine.enqueue(list, Array(UnsafeBufferPointer(start: flags, count: count)), Array(UnsafeBufferPointer(start: ids, count: count)))
}

final class Engine: ObservableObject {
    static let shared = Engine(dataDir: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DiskChrona"))

    static let batchLimit = 5000
    static let pendingCap = 50_000
    static let minFreeBytes: Int64 = 512 << 20

    @Published private(set) var status = EngineStatus()
    /// Net bytes per minute for the menu bar: published on its own so a hidden window is not refreshed for it.
    @Published private(set) var rate: Int64 = 0
    /// Main thread, like the settings binding and the views consuming it.
    @Published var ignoreSwap: Bool {
        didSet {
            defaults.set(ignoreSwap, forKey: "ignoreSwap")
            work.async { [self] in publish() }
        }
    }

    /// Main thread. While both views are hidden only menu-bar-relevant changes are published: saves CPU, and an
    /// occluded SwiftUI window otherwise piles up un-rendered updates that keep every old result alive.
    var windowVisible = true { didSet { if windowVisible, let latest { status = latest } } }
    var menuVisible = false { didSet { if menuVisible, let latest { status = latest } } }
    private var latest: EngineStatus?

    let reader: DB
    let databasePath: String
    private let db: DB
    private let dataPath: String
    private let defaults: UserDefaults
    private let work = DispatchQueue(label: "DiskChrona.work", qos: .utility)
    private let readQ = DispatchQueue(label: "DiskChrona.read", qos: .userInitiated)
    private let eventQ = DispatchQueue(label: "DiskChrona.events", qos: .utility)

    // Shared with the FSEvents queue; guarded by `lock`.
    private let lock = NSLock()
    private var pendingFiles: [String: UInt32] = [:]
    private var pendingDirs: [String: UInt32] = [:]
    private var seenEventId: UInt64 = 0
    private var historyDone = true
    private var drainScheduled = false
    private var scopeRoots: [Root] = []

    // Work queue only.
    private var st = EngineStatus()
    private var stream: FSEventStreamRef?
    private var started = false
    private var jobs: [Job] = []
    private var jobLoop = false
    private var confirmed: Double = 0
    private var lastBeat: Double = 0
    private var sessionId: Int64?
    private var sessionWritten: Double = 0
    private var lastHousekeeping: Double = 0
    private var lastMaintain: Double = 0
    private var writeFailed = false
    // Observed since the last flush: latest file state (nil = deleted) and the changes to record. One transaction a minute.
    private var overlay: [String: FileRow?] = [:]
    private var overlayInode: [String: Set<String>] = [:]
    private var pending: [Pending] = []
    private var foldInto: [String: Int] = [:]
    private var lastFlush: Double = 0
    private var lastRefresh: Double = 0
    private var meter = RateMeter()
    private var dirty = false
    private var publishScheduled = false
    private var timer: DispatchSourceTimer?

    init(dataDir: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ignoreSwap = defaults.bool(forKey: "ignoreSwap")
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        dataPath = canonical(dataDir.path)
        databasePath = dataDir.appendingPathComponent("DiskChrona.sqlite").path
        do {
            db = try DB(path: databasePath)
            try db.migrate()
            reader = try DB(path: databasePath)
        } catch { fatalError("Can't open database \(databasePath): \(error)") }
        let now = Date().timeIntervalSince1970
        work.sync {
            loadRoots()
            confirmed = (try? db.double("SELECT MAX(ended) FROM sessions")) ?? now
            st.earliest = (try? db.double("SELECT MIN(ts_prev) FROM changes")).map(Date.init(timeIntervalSince1970:))
            st.dataBytes = dataSize()
        }
        status = st
    }

    // MARK: Public API (any thread)

    func start() {
        work.async { [self] in
            guard !started else { return }
            started = true
            let now = Date().timeIntervalSince1970
            let cursor = meta("event_id").flatMap(UInt64.init)
            checkJournal(hasCursor: cursor != nil)
            if st.roots.isEmpty {   // the whole disk is the scope; users only exclude
                _ = try? db.run("INSERT OR IGNORE INTO roots(path) VALUES('/')")
                loadRoots()
            }
            startStream(since: cursor ?? FSEventsGetCurrentEventId())
            if cursor == nil { persistCursor(force: true) }
            startSession(now)
            let t = DispatchSource.makeTimerSource(queue: work)
            t.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(2))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            housekeeping(now)
            scheduleDrain()
            publish()
        }
    }

    func shutdown() {
        work.sync {
            stopStream()
            do { try flush() } catch { fail(error) }
            endSession(Date().timeIntervalSince1970)
            persistCursor()
        }
    }

    func setPaused(_ paused: Bool) {
        work.async { [self] in
            guard started, paused != st.paused else { return }
            let now = Date().timeIntervalSince1970
            st.paused = paused
            if paused {
                stopStream()
                do { try flush() } catch { fail(error) }
                endSession(now)
            } else {
                // Replays everything since the last event we saw, so changes made while paused are re-checked.
                startStream(since: lock.withLock { seenEventId })
                startSession(now)
                scheduleDrain()
            }
            publish()
        }
    }

    func addRoot(_ path: String) {
        let path = canonical(path)
        work.async { [self] in
            do { try db.run("INSERT OR IGNORE INTO roots(path) VALUES(?)", [path]) } catch { return fail(error) }
            loadRoots()
            restartStream()
            publish()
        }
    }

    func setExcludes(_ id: Int64, _ excludes: [String]) {
        work.async { [self] in
            do { try db.run("UPDATE roots SET excludes = ? WHERE id = ?", [excludes.map(canonical).joined(separator: "\n"), id]) } catch { return fail(error) }
            loadRoots()
            guard let root = st.roots.first(where: { $0.id == id }) else { return }
            try? flush()
            pruneOutOfScope(under: root.path)
            publish()
        }
    }

    func clearHistory() {
        work.async { [self] in
            do {
                try flush()
                try db.exec("DELETE FROM changes; DELETE FROM sessions;")
                if sessionId != nil { startSession(Date().timeIntervalSince1970) }
                compact()
            } catch { return fail(error) }
            st.earliest = nil
            st.dataBytes = dataSize()
            dirty = true
            publish()
        }
    }

    func maintainNow() { work.async { [self] in maintain(); publish() } }

    func read<T>(_ body: @escaping (DB) throws -> T) async -> T? {
        await withCheckedContinuation { c in readQ.async { c.resume(returning: try? body(self.reader)) } }
    }

    func gaps(in iv: DateInterval, live: Date?) async -> [DateInterval] {
        var sessions = await read { try $0.sessions(iv) } ?? []
        if let live { sessions.append(DateInterval(start: live, end: .distantFuture)) }
        return coverageGaps(iv, sessions)
    }

    // MARK: Events

    func enqueue(_ paths: [String], _ flags: [UInt32], _ ids: [UInt64]) {
        lock.lock()
        for (i, raw) in paths.enumerated() {
            let f = flags[i]
            let p = raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            seenEventId = max(seenEventId, ids[i])
            if has(f, kFSEventStreamEventFlagHistoryDone) { historyDone = true; continue }
            if has(f, kFSEventStreamEventFlagEventIdsWrapped) { for r in scopeRoots { pendingDirs[r.path, default: 0] |= f }; continue }
            // Coalesced or dropped events: the directory must be re-checked as a whole.
            if has(f, kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) { pendingDirs[p, default: 0] |= f; continue }
            guard !covering(p, scopeRoots).isEmpty else { continue }
            if has(f, kFSEventStreamEventFlagItemIsDir) {
                if has(f, kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) { pendingDirs[p, default: 0] |= f }
            } else {
                pendingFiles[p, default: 0] |= f
            }
        }
        if pendingFiles.count > Engine.pendingCap {
            // ponytail: overflow degrades to directory rescans; bounded memory over per-file precision.
            for p in pendingFiles.keys { pendingDirs[(p as NSString).deletingLastPathComponent, default: 0] |= 0 }
            pendingFiles.removeAll()
        }
        var depth = 8
        while pendingDirs.count > 1000 && depth > 1 {   // too many directories: merge into shallower ancestors, never the whole disk at once
            pendingDirs = Dictionary(pendingDirs.map { ("/" + $0.key.split(separator: "/").prefix(depth).joined(separator: "/"), $0.value) }, uniquingKeysWith: |)
            depth -= 1
        }
        // Nothing queued (only our own database writes, say): no drain, or its cursor write becomes the next event.
        let schedule = !drainScheduled && !(pendingFiles.isEmpty && pendingDirs.isEmpty)
        if schedule { drainScheduled = true }
        lock.unlock()
        if schedule { work.async { self.drain() } }
    }

    private func covering(_ p: String, _ roots: [Root]) -> [Root] {
        isUnder(p, dataPath) ? [] : roots.filter { isUnder(p, $0.path) && !$0.excludes.contains { isUnder(p, $0) } }
    }

    private func startStream(since: UInt64) {
        stopStream()
        let paths = st.roots.map(\.path)
        lock.withLock {
            seenEventId = max(seenEventId, since)
            historyDone = paths.isEmpty
        }
        guard !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        // 5 s batches: one transaction per batch instead of per second, so hot database pages are rewritten far less often.
        guard let s = FSEventStreamCreate(nil, eventCallback, &ctx, paths as CFArray, since, 5.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, eventQ)
        FSEventStreamStart(s)
        stream = s
    }

    private func stopStream() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    private func restartStream() {
        guard started, !st.paused else { return }
        startStream(since: lock.withLock { seenEventId })
    }

    /// A reset FSEvents journal cannot replay history; fall back to rescanning.
    private func checkJournal(hasCursor: Bool) {
        for r in st.roots {
            var s = stat()
            guard lstat(r.path, &s) == 0, let uuid = FSEventsCopyUUIDForDevice(s.st_dev) else { continue }
            let key = "fsevents_uuid_\(s.st_dev)", value = CFUUIDCreateString(nil, uuid) as String
            let old = meta(key)
            if !hasCursor || (old != nil && old != value) { lock.withLock { pendingDirs[r.path, default: 0] |= 0 } }
            _ = try? db.run("INSERT OR REPLACE INTO meta(k, v) VALUES(?, ?)", [key, value])
        }
    }

    // MARK: Batch processing (work queue)

    private func scheduleDrain() {
        let schedule = lock.withLock { () -> Bool in
            defer { drainScheduled = true }
            return !drainScheduled
        }
        if schedule { work.async { self.drain() } }
    }

    private func drain() {
        lock.lock()
        drainScheduled = false
        guard !st.paused, st.limited == nil else { lock.unlock(); return }
        let dirs = pendingDirs
        pendingDirs.removeAll()
        var take: [String: UInt32] = [:]
        var stale: [String] = []
        for (p, f) in pendingFiles {
            let roots = covering(p, st.roots)
            if roots.isEmpty { stale.append(p); continue }
            take[p] = f
            if take.count >= Engine.batchLimit { break }
        }
        for p in take.keys { pendingFiles[p] = nil }
        for p in stale { pendingFiles[p] = nil }
        lock.unlock()

        queueRescans(dirs)
        if !take.isEmpty {
            do {
                try reconcile(take.keys.reduce(into: [:]) { $0[$1] = observe($1) }, flags: take)
            } catch {
                lock.withLock { pendingFiles.merge(take) { $0 | $1 } }
                return fail(error)
            }
            st.confirmedAt = Date(timeIntervalSince1970: max(confirmed, lastBeat))
        }
        if take.count >= Engine.batchLimit { work.asyncAfter(deadline: .now() + 0.2) { self.scheduleDrain() } }
        runJobs()
        publish()
    }

    private func queueRescans(_ dirs: [String: UInt32]) {
        var targets: [String: UInt32] = [:]
        for (d, f) in dirs {
            if !covering(d, st.roots).isEmpty { targets[d, default: 0] |= f }
            else { for r in st.roots where isUnder(r.path, d) { targets[r.path, default: 0] |= f } }   // event above a root
        }
        targets = targets.filter { t in !targets.keys.contains { $0 != t.key && isUnder(t.key, $0) } }
        let live = Set(targets.keys.filter { FileManager.default.fileExists(atPath: $0) })
        // Known files vanished with a directory: walk directories renamed in the same batch to find them.
        // Otherwise never walk; checking known rows is a database range scan, not a disk crawl.
        let movedAway = targets.keys.contains { !live.contains($0) && hasRows(under: $0) }
        // Existing directories first, so a rename resolves as a move before its old path is checked.
        for d in live.sorted() + targets.keys.filter({ !live.contains($0) }).sorted()
        where !jobs.contains(where: { $0.cursor == nil && $0.walker == nil && isUnder(d, $0.dir) }) {
            jobs.append(Job(d, walk: movedAway && live.contains(d) && has(targets[d]!, kFSEventStreamEventFlagItemRenamed)))
        }
    }

    private func hasRows(under dir: String) -> Bool {
        let (lo, hi) = prefixRange(dir)
        if overlay.contains(where: { $0.value != nil && isUnder($0.key, dir) }) { return true }
        return ((try? db.rows("SELECT 1 FROM files WHERE path >= ? AND path < ? LIMIT 1", [lo, hi]) { _ in true }) ?? []).isEmpty == false
    }

    private func runJobs() {
        guard !jobLoop, !jobs.isEmpty else { return }
        jobLoop = true
        work.async { self.stepJob() }
    }

    private func stepJob() {
        guard !st.paused, st.limited == nil, let job = jobs.first else { jobLoop = false; publish(); return }
        do {
            try stepRescan(job)
        } catch {
            jobLoop = false
            return fail(error)
        }
        publish()
        work.async { self.stepJob() }
    }

    private func stepRescan(_ job: Job) throws {
        if job.cursor == nil {
            if job.walk {
                if job.walker == nil { job.walker = Walker(job.dir) { [self] p in covering(p, st.roots).isEmpty } }
                if let batch = job.walker!.next(2000) {
                    try reconcile(batch.reduce(into: [:]) { $0[$1.0] = .file($1.1) })
                    return
                }
            }
            job.cursor = ""
        }
        // Known rows not touched since the job started: changed, deleted, moved away, or merely unreadable.
        let (lo, hi) = prefixRange(job.dir)
        let saved = try db.rows("SELECT path FROM files WHERE path >= ? AND path < ? AND path > ? AND seen_at < ? ORDER BY path LIMIT 2000",
                                [lo, hi, job.cursor!, job.started]) { $0.string(0) ?? "" }
        // A directory event can arrive before the minute's first file observations are flushed.
        let buffered = overlay.compactMap { p, r in
            p >= lo && p < hi && p > job.cursor! && (r?.seenAt ?? .infinity) < job.started ? p : nil
        }
        let paths = Set(saved).union(buffered).sorted().prefix(2000)
        guard let last = paths.last else { jobs.removeFirst(); scheduleDrain(); return }
        job.cursor = last
        try reconcile(paths.reduce(into: [:]) { $0[$1] = observe($1) })
    }

    /// Compares fresh observations with the last known sizes and records observed changes.
    private func reconcile(_ obs: [String: Obs], flags: [String: UInt32] = [:]) throws {
        let now = Date().timeIntervalSince1970
        var rootOnline: [String: Bool] = [:]
        /// A missing path is a deletion only if its volume is still there: the root exists and the
        /// nearest surviving ancestor sits on the file's device (an unmounted volume is not a deletion).
        func isOnline(_ p: String, dev: Int64) -> Bool {
            guard let r = covering(p, st.roots).first?.path else { return false }
            var s = stat()
            if rootOnline[r] == nil { rootOnline[r] = lstat(r, &s) == 0 }
            guard rootOnline[r]! else { return false }
            var dir = (p as NSString).deletingLastPathComponent
            while lstat(dir, &s) != 0 {
                guard dir != "/" && !dir.isEmpty else { return false }
                dir = (dir as NSString).deletingLastPathComponent
            }
            return Int64(s.st_dev) == dev
        }
        func renamed(_ p: String) -> Bool { has(flags[p] ?? 0, kFSEventStreamEventFlagItemRenamed) }

        var newcomers: [(String, Stat)] = []
        var gone: [String: FileRow] = [:]
        for (p, o) in obs {
            switch (o, try known(p)) {
            case let (.file(s), r?):
                if s.size != r.size || s.alloc != r.alloc {
                    record(kind(r.sizes, s.sizes), p, prev: r.seenAt, old: r.sizes, new: s.sizes, at: now)
                    // Hard links share data: update siblings so the same growth is never counted twice.
                    if s.nlink > 1 {
                        try db.run("UPDATE files SET size = ?, alloc = ?, seen_at = ? WHERE dev = ? AND ino = ? AND path != ?", [s.size, s.alloc, now, s.dev, s.ino, p])
                        for (q, o) in overlay where q != p && o?.dev == s.dev && o?.ino == s.ino { overlay[q] = FileRow(q, s, seenAt: now) }
                    }
                }
                remember(p, s, now)
            case let (.file(s), nil):
                newcomers.append((p, s))
            case let (.gone, r?) where isOnline(p, dev: r.dev):
                gone[p] = r
            case (.unknown, _):
                noteUnreadable(p)
            default:
                break   // unreadable or volume offline: keep the last known state, never a deletion
            }
        }

        var goneByInode: [String: String] = [:]
        for r in gone.values { goneByInode["\(r.dev):\(r.ino)"] = r.path }
        for (p, s) in newcomers {
            if let old = goneByInode.removeValue(forKey: "\(s.dev):\(s.ino)"), let r = gone.removeValue(forKey: old) {
                move(r, to: p, s, now)
                continue
            }
            if let r = try known(dev: s.dev, ino: s.ino) {
                switch observe(r.path) {
                case .file(let t) where t.dev == s.dev && t.ino == s.ino:
                    remember(p, s, now)   // new hard link to data we already track
                    continue
                case .gone where isOnline(r.path, dev: r.dev):
                    gone[r.path] = nil
                    move(r, to: p, s, now)
                    continue
                default: break
                }
            }
            // No upfront scan: an unknown file is new only if FSEvents says it was created. Otherwise
            // this is its first observation and the earlier size is unknown, so it is not growth.
            if has(flags[p] ?? 0, kFSEventStreamEventFlagItemCreated) {
                record(.added, p, prev: confirmed, new: s.sizes, at: now)
            } else if flags[p] != nil {
                record(.firstSeen, p, prev: now, old: s.sizes, new: s.sizes, at: now)
            } else {
                continue   // only walked by a rescan: nothing to compare against yet
            }
            remember(p, s, now)
        }

        for (p, r) in gone {
            forget(p)
            if try known(dev: r.dev, ino: r.ino) != nil { continue }   // another hard link still holds the data
            record(renamed(p) ? .scopeOut : .deleted, p, prev: r.seenAt, old: r.sizes, at: now)
        }
    }

    // MARK: Buffered state (work queue)

    /// Last known state of a path: this minute's observation first, then the database.
    private func known(_ p: String) throws -> FileRow? {
        if let r = overlay[p] { return r }
        return try db.file(p)
    }

    private func known(dev: Int64, ino: Int64) throws -> FileRow? {
        for p in overlayInode["\(dev):\(ino)"] ?? [] {
            if let r = overlay[p] ?? nil, r.dev == dev, r.ino == ino { return r }
        }
        for r in try db.files(dev: dev, ino: ino) {
            guard let o = overlay[r.path] else { return r }
            if let o, o.dev == dev, o.ino == ino { return o }   // else deleted or replaced since
        }
        return nil
    }

    private func remember(_ p: String, _ s: Stat, _ now: Double) {
        overlay[p] = FileRow(p, s, seenAt: now)
        overlayInode["\(s.dev):\(s.ino)", default: []].insert(p)
    }

    private func forget(_ p: String) { overlay.updateValue(nil, forKey: p) }

    /// Writes the minute's observations in one transaction; the cursor follows once nothing is unsaved.
    private func flush() throws {
        guard !overlay.isEmpty || !pending.isEmpty else { return }
        try db.transaction {
            for (p, r) in overlay {
                if let r {
                    try db.run("INSERT OR REPLACE INTO files(path, dev, ino, size, alloc, nlink, mtime, seen_at) VALUES(?,?,?,?,?,?,?,?)",
                               [p, r.dev, r.ino, r.size, r.alloc, r.nlink, r.mtime, r.seenAt])
                } else {
                    try db.run("DELETE FROM files WHERE path = ?", [p])
                }
            }
            for e in pending where !e.empty {
                try db.run("INSERT INTO changes(ts_prev, ts, path, other_path, kind, old_size, new_size, old_alloc, new_alloc) VALUES(?,?,?,?,?,?,?,?,?)",
                           [e.prev, e.ts, e.path, e.other, e.kind.rawValue, e.old.0, e.new.0, e.old.1, e.new.1])
                dirty = true
            }
        }
        overlay.removeAll(); overlayInode.removeAll(); pending.removeAll(); foldInto.removeAll()
        persistCursor()
    }

    /// Coverage: remember where permission (or I/O) errors hide changes from us.
    private func noteUnreadable(_ p: String) {
        guard let r = covering(p, st.roots).first else { return }
        let dir = (p as NSString).deletingLastPathComponent
        var state = st.states[r.id, default: RootState()]
        guard state.unreadable.count < 200, !state.unreadable.contains(dir) else { return }
        state.unreadable.append(dir)
        st.states[r.id] = state
    }

    private func kind(_ old: (Int64, Int64), _ new: (Int64, Int64)) -> Kind {
        new.0 > old.0 || (new.0 == old.0 && new.1 > old.1) ? .grew : .shrank
    }

    /// A move is a transfer between directories: out of one, into the other, net zero globally.
    private func move(_ r: FileRow, to p: String, _ s: Stat, _ now: Double) {
        forget(r.path)
        record(.moveOut, r.path, other: p, prev: r.seenAt, old: r.sizes, at: now)
        record(.moveIn, p, other: r.path, prev: r.seenAt, new: r.sizes, at: now)
        if s.size != r.size || s.alloc != r.alloc { record(kind(r.sizes, s.sizes), p, prev: r.seenAt, old: r.sizes, new: s.sizes, at: now) }
        remember(p, s, now)
    }

    /// Queues a change; a size change of a path already queued this minute folds into that row instead.
    private func record(_ kind: Kind, _ path: String, other: String? = nil, prev: Double, old: (Int64, Int64) = (0, 0), new: (Int64, Int64) = (0, 0), at now: Double) {
        // The change happened somewhere between the last confirmed observation and now.
        let prev = min(max(prev, confirmed), now)
        if kind != .moveIn && kind != .moveOut { meter.add(new.0 - old.0, at: now, isSwap: isSwapFile(path)) }   // moves are transfers, not growth
        if [.grew, .shrank, .firstSeen, .added].contains(kind), let i = foldInto[path] {
            pending[i].new = new
            pending[i].ts = now
            pending[i].prev = min(pending[i].prev, prev)
            if pending[i].kind != .added { pending[i].kind = pending[i].seen && pending[i].old == new ? .firstSeen : self.kind(pending[i].old, new) }
            return
        }
        pending.append(Pending(kind: kind, path: path, other: other, prev: prev, old: old, new: new, ts: now, seen: kind == .firstSeen))
        foldInto[path] = pending.last!.foldable ? pending.count - 1 : nil
    }

    // MARK: Sessions, health, retention (work queue)

    private func tick(_ now: Double = Date().timeIntervalSince1970) {
        defer { publish() }
        // Rolling queries age even when no files change or monitoring is paused.
        if now - lastRefresh >= 60 { lastRefresh = now; dirty = true }
        guard !st.paused else { return }
        if now - lastFlush >= 60 {
            lastFlush = now
            do { try flush() } catch { fail(error) }
        }
        if now - lastBeat > 60 {
            // Slept or stalled: the stretch since the last beat becomes a visible coverage gap.
            endSession(lastBeat)
            startSession(now)
        } else {
            let idle = lock.withLock { pendingFiles.isEmpty && pendingDirs.isEmpty && historyDone }
            if idle && jobs.isEmpty {
                confirmed = max(confirmed, lastBeat)
                st.confirmedAt = Date(timeIntervalSince1970: confirmed)
            }
            if now - sessionWritten >= 60, let id = sessionId {
                _ = try? db.run("UPDATE sessions SET ended = ? WHERE id = ?", [now, id])
                sessionWritten = now
            }
        }
        lastBeat = now
        if now - lastHousekeeping >= 60 { housekeeping(now) }
    }

    private func startSession(_ now: Double) {
        _ = try? db.run("INSERT INTO sessions(started, ended) VALUES(?, ?)", [now, now])
        sessionId = db.lastInsertId
        lastBeat = now
        sessionWritten = now
        st.sessionStart = Date(timeIntervalSince1970: now)
    }

    private func endSession(_ at: Double) {
        guard let id = sessionId else { return }
        _ = try? db.run("UPDATE sessions SET ended = ? WHERE id = ?", [at, id])
        sessionId = nil
        st.sessionStart = nil
    }

    private func housekeeping(_ now: Double) {
        lastHousekeeping = now
        for r in st.roots {
            let was = st.states[r.id]?.problem
            let p = problem(of: r.path)
            st.states[r.id, default: RootState()].problem = p
            if was != nil && p == nil {   // came back: re-check everything under it
                lock.withLock { pendingDirs[r.path, default: 0] |= 0 }
                scheduleDrain()
            }
        }
        // Real free space (statfs), excluding purgeable space, sampled once a minute for the trend.
        let free = (try? URL(fileURLWithPath: dataPath).resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
        st.volumeFree = free
        if let free { _ = try? db.run("INSERT INTO volume(ts, free) VALUES(?, ?)", [now, free]) }
        if let free, free < Engine.minFreeBytes {
            st.limited = "Less than \(ByteCountFormatter.string(fromByteCount: Engine.minFreeBytes, countStyle: .file)) of disk space is free, so recording has stopped growing. Changes will be caught up once space is freed."
        } else if st.limited != nil {
            // Space recovered, or retry once a minute after a write failure (no retry storm, no log growth).
            st.limited = nil
            writeFailed = false
            scheduleDrain()
            runJobs()
        }
        if now - lastMaintain >= 3600 { maintain() }
        st.dataBytes = dataSize()
    }

    private func maintain() {
        let now = Date().timeIntervalSince1970
        lastMaintain = now
        let defaults = UserDefaults.standard
        let days = defaults.object(forKey: "retentionDays") as? Int ?? 30
        let budget = Int64(defaults.object(forKey: "budgetMiB") as? Int ?? 500) << 20
        let cutoff = now - Double(days) * 86400
        do {
            try flush()
            while try db.run("DELETE FROM changes WHERE id IN (SELECT id FROM changes WHERE ts < ? LIMIT 5000)", [cutoff]) == 5000 {}
            try db.run("DELETE FROM sessions WHERE ended < ?", [cutoff])
            try db.run("DELETE FROM volume WHERE ts < ?", [cutoff])
            try db.run("DELETE FROM files WHERE seen_at < ?", [cutoff])   // a cache of last-seen sizes; untouched files are first-seen again
            compact()
            st.warning = nil
            var trimmed = false
            while dataSize() > budget {
                guard try db.run("DELETE FROM changes WHERE id IN (SELECT id FROM changes ORDER BY id LIMIT 20000)") > 0 else {
                    st.warning = "Current file size records alone exceed the size budget. Exclude high-churn folders or raise the budget."
                    break
                }
                trimmed = true
                compact()
            }
            st.earliest = try db.double("SELECT MIN(ts_prev) FROM changes").map(Date.init(timeIntervalSince1970:))
            if trimmed, st.warning == nil, let e = st.earliest {
                st.warning = "The oldest history was trimmed to fit the size budget. Earliest available: \(e.formatted(date: .abbreviated, time: .shortened))."
            }
            st.dataBytes = dataSize()
            dirty = true
        } catch { fail(error) }
    }

    private func compact() {
        try? db.exec("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA incremental_vacuum; PRAGMA wal_checkpoint(TRUNCATE);")
    }

    // MARK: Helpers (work queue)

    private func loadRoots() {
        st.roots = (try? db.rows("SELECT id, path, excludes FROM roots ORDER BY path") { r in
            Root(id: r.int(0), path: r.string(1) ?? "", excludes: (r.string(2) ?? "").split(separator: "\n").map(String.init))
        }) ?? []
        lock.withLock { scopeRoots = st.roots }
    }

    private func pruneOutOfScope(under dir: String) {
        let (lo, hi) = prefixRange(dir)
        let paths = (try? db.rows("SELECT path FROM files WHERE path >= ? AND path < ?", [lo, hi]) { $0.string(0) ?? "" }) ?? []
        let stale = paths.filter { covering($0, st.roots).isEmpty }
        do { try db.transaction { for p in stale { try db.run("DELETE FROM files WHERE path = ?", [p]) } } } catch { fail(error) }
    }

    /// Persists the FSEvents cursor only once everything up to it is reflected in the database.
    private func persistCursor(force: Bool = false) {
        let (idle, id) = lock.withLock { (pendingFiles.isEmpty && pendingDirs.isEmpty, seenEventId) }
        guard overlay.isEmpty && pending.isEmpty,
              force || (idle && !writeFailed && jobs.isEmpty) else { return }
        _ = try? db.run("INSERT OR REPLACE INTO meta(k, v) VALUES('event_id', ?)", [String(id)])
    }

    private func meta(_ key: String) -> String? {
        (try? db.rows("SELECT v FROM meta WHERE k = ?", [key]) { $0.string(0) })?.first ?? nil
    }

    private func problem(of path: String) -> String? {
        guard let d = opendir(path) else { return problemText(errno) }
        closedir(d)
        return nil
    }

    private func problemText(_ e: Int32) -> String {
        e == ENOENT ? "Offline (folder missing or volume not mounted)" : "Permission denied (\(String(cString: strerror(e))))"
    }

    private func dataSize() -> Int64 {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: dataPath)) ?? []).reduce(0) {
            $0 + ((try? fm.attributesOfItem(atPath: dataPath + "/" + $1)[.size] as? Int64) ?? 0)
        }
    }

    private func fail(_ error: Error) {
        writeFailed = true
        st.limited = "Database write failed, so recording has stopped (\(error)). Unsaved changes are not marked as recorded; retrying every minute."
        publish()
    }

    private func publish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        work.asyncAfter(deadline: .now() + 0.5) { [self] in
            publishScheduled = false
            st.backlog = lock.withLock { pendingFiles.count + pendingDirs.count }
            st.rescanning = !jobs.isEmpty
            if dirty { st.revision += 1; dirty = false }
            let snapshot = st
            let now = Date().timeIntervalSince1970
            let allRate = meter.sum(at: now), filteredRate = meter.sum(at: now, ignoreSwap: true)
            DispatchQueue.main.async {
                let rate = self.ignoreSwap ? filteredRate : allRate
                if rate != self.rate { self.rate = rate }
                self.latest = snapshot
                if self.windowVisible || self.menuVisible || (snapshot.paused, snapshot.symbol) != (self.status.paused, self.status.symbol) { self.status = snapshot }
            }
        }
    }

    // MARK: Test hooks

    func checkTime(_ now: Date) { work.sync { tick(now.timeIntervalSince1970) } }

    /// Reconciles `paths` as an FSEvents batch with `flags`, or as a rescan when `flags` is nil, then flushes.
    func check(_ paths: [String], flags: UInt32? = UInt32(kFSEventStreamEventFlagItemModified), flush: Bool = true) throws {
        let fl: [String: UInt32] = flags.map { f in paths.reduce(into: [:]) { $0[$1] = f } } ?? [:]
        try work.sync {
            try reconcile(paths.reduce(into: [:]) { $0[$1] = observe($1) }, flags: fl)
            if flush { try self.flush() }
        }
    }

    /// Waits for queued events and rescans, then flushes what they observed.
    func waitIdle() {
        while !work.sync(execute: { jobs.isEmpty && !jobLoop && lock.withLock { pendingFiles.isEmpty && pendingDirs.isEmpty && !drainScheduled } }) {
            usleep(20_000)
        }
        work.sync { try? flush() }
    }
}
