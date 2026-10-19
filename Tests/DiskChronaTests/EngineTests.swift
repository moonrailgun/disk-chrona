import Combine
import CoreServices
import XCTest
@testable import DiskChrona

/// Fixed file-operation sequences checked against what the engine records (PRD §9).
final class EngineTests: XCTestCase {
    private var tmp = ""
    private var root: String { tmp + "/root" }
    private var engine: Engine!

    override func setUpWithError() throws {
        tmp = canonical(NSTemporaryDirectory()) + "/diskchrona-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)
        engine = Engine(dataDir: URL(fileURLWithPath: tmp + "/data"))
    }

    override func tearDown() {
        chmod(root + "/sub", 0o755)
        try? FileManager.default.removeItem(atPath: tmp)
    }

    private func changes() throws -> [Change] {
        try engine.reader.rows("SELECT \(Change.columns) FROM changes ORDER BY id", map: Change.init)
    }

    private func write(_ path: String, _ count: Int, append: Bool = false) throws {
        let data = Data(repeating: 7, count: count)
        if append, let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(data); h.closeFile()
        } else {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }

    func testRecordedChanges() throws {
        let log = root + "/app.log", big = root + "/big.bin", locked = root + "/sub/locked.bin"
        try write(log, 1000)
        try write(big, 5_000_000)
        try write(locked, 10)
        engine.addRoot(root)
        engine.waitIdle()
        try engine.check([log, big, locked], flags: nil)
        XCTAssertEqual(try changes().count, 0, "a rescan walk of never-seen files reports nothing")
        try engine.check([log, big, locked])
        XCTAssertEqual(try changes().map(\.kind), [.firstSeen, .firstSeen, .firstSeen], "first write to a pre-existing file is not growth")

        try write(log, 500, append: true)
        try engine.check([log])
        var c = Array(try changes().dropFirst(3))
        XCTAssertEqual(c.map(\.kind), [.grew])
        XCTAssertEqual(c[0].newSize - c[0].oldSize, 500)
        XCTAssertLessThanOrEqual(c[0].tsPrev, c[0].ts)

        try write(log, 1500)   // same-length overwrite
        try engine.check([log])
        XCTAssertEqual(try changes().count, 4, "rewriting the same length is not growth")

        let moved = root + "/sub/app.log"
        try FileManager.default.moveItem(atPath: log, toPath: moved)
        try engine.check([log, moved])
        XCTAssertEqual(try changes().suffix(2).map(\.kind), [.moveOut, .moveIn])
        XCTAssertEqual(try engine.reader.history(moved).map(\.kind), [.firstSeen, .grew, .moveIn], "history follows the move")

        let link = root + "/sub/link.log"
        XCTAssertEqual(Darwin.link(moved, link), 0)
        try engine.check([link])
        XCTAssertEqual(try changes().count, 6, "a new hard link adds no data")
        try write(moved, 100, append: true)
        try engine.check([moved, link])
        XCTAssertEqual(try changes().count, 7, "growth of hard-linked data counts once")

        chmod(root + "/sub", 0)
        try engine.check([locked])
        chmod(root + "/sub", 0o755)
        XCTAssertEqual(try changes().count, 7, "unreadable is unknown, not deleted")

        try FileManager.default.removeItem(atPath: big)
        try engine.check([big])
        c = try changes()
        XCTAssertEqual(c.last?.kind, .deleted)
        XCTAssertEqual(c.last?.oldSize, 5_000_000)

        let fresh = root + "/model.bin"
        try write(fresh, 42)
        try engine.check([fresh], flags: UInt32(kFSEventStreamEventFlagItemCreated))
        XCTAssertEqual(try changes().last?.kind, .added)

        let iv = DateInterval(start: .distantPast, end: .distantFuture)
        let files = try engine.reader.ranking(iv, metric: .size, sort: .growth, search: "", byDir: false, dir: "/")
        XCTAssertEqual(files.filter { [moved, link].contains($0.path) }.reduce(0) { $0 + $1.net }, 100, "moves are not file growth; hard-linked growth may land on either path")
        XCTAssertEqual(files.reduce(0) { $0 + $1.net }, 500 + 100 + 42 - 5_000_000)
        let dirs = try engine.reader.ranking(iv, metric: .size, sort: .growth, search: "", byDir: true, dir: root)
        XCTAssertEqual(dirs.first { $0.name == "sub" }?.net, 1500 + 100, "a move in is a transfer into the directory")
    }

    func testDirectoryRenameIsAMove() throws {
        try write(root + "/sub/f.bin", 2048)
        engine.addRoot(root)
        engine.waitIdle()
        try engine.check([root + "/sub/f.bin"])
        try FileManager.default.moveItem(atPath: root + "/sub", toPath: root + "/sub2")
        let flags = UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed)
        engine.enqueue([root + "/sub", root + "/sub2"], [flags, flags], [1, 2])
        engine.waitIdle()
        XCTAssertEqual(try changes().map(\.kind), [.firstSeen, .moveOut, .moveIn])
    }

    func testOfflineRootIsNotMassDeletion() throws {
        try write(root + "/f.bin", 10)
        engine.addRoot(root)
        engine.waitIdle()
        try engine.check([root + "/f.bin"])
        try FileManager.default.moveItem(atPath: root, toPath: tmp + "/elsewhere")
        engine.enqueue([root], [UInt32(kFSEventStreamEventFlagMustScanSubDirs)], [1])
        engine.waitIdle()
        XCTAssertEqual(try changes().map(\.kind), [.firstSeen])
    }

    func testRateMeterSlides() {
        var m = RateMeter()
        m.add(100, at: 1000)
        m.add(-30, at: 1030.5)
        XCTAssertEqual(m.sum(at: 1059), 70)
        XCTAssertEqual(m.sum(at: 1061), -30, "the first sample is older than 60 s")
        XCTAssertEqual(m.sum(at: 1200), 0)
        m.add(5, at: 1060)   // reuses the slot of t = 1000
        XCTAssertEqual(m.sum(at: 1060), -25)
    }

    func testObservationsAggregateUntilFlush() throws {
        let f = root + "/f.bin", g = root + "/g.bin"
        try write(f, 100)
        try write(g, 100)
        engine.addRoot(root)
        engine.waitIdle()
        try engine.check([f, g])                 // first seen, flushed
        try write(f, 200, append: true)
        try write(g, 50, append: true)
        try engine.check([f, g], flush: false)
        try write(f, 300, append: true)
        try write(g, 100)                        // back to its original size
        try engine.check([f, g])
        let c = Array(try changes().dropFirst(2))
        XCTAssertEqual(c.map(\.kind), [.grew], "one row per file per flush; a net-zero minute leaves no row")
        XCTAssertEqual(c.first.map { ($0.path, $0.oldSize, $0.newSize) }.map { [$0.0, "\($0.1)", "\($0.2)"] }, [f, "100", "600"])
        XCTAssertEqual(try engine.reader.file(f)?.size, 600)
        XCTAssertEqual(try engine.reader.file(g)?.size, 100)
    }

    func testOwnDatabaseWritesScheduleNoWork() throws {
        engine.addRoot(tmp)   // like '/', the root contains the data directory
        engine.waitIdle()
        engine.enqueue([tmp + "/data/DiskChrona.sqlite-wal"], [UInt32(kFSEventStreamEventFlagItemModified)], [99])
        engine.waitIdle()
        XCTAssertTrue(try engine.reader.rows("SELECT v FROM meta WHERE k = 'event_id'") { _ in () }.isEmpty,
                      "a drain here persists the cursor, and that write is the next event: an endless loop")
    }

    func testFailedShutdownKeepsReplayCursor() throws {
        let f = root + "/f.bin"
        try write(f, 100)
        engine.addRoot(root)
        engine.waitIdle()
        try engine.check([f])
        let cursor = try engine.reader.rows("SELECT v FROM meta WHERE k = 'event_id'") { $0.string(0) }
        try write(f, 200)
        engine.enqueue([f], [UInt32(kFSEventStreamEventFlagItemModified)], [99])
        try engine.check([], flush: false)   // wait for the event to reach the buffer
        try engine.reader.exec("CREATE TRIGGER fail_changes BEFORE INSERT ON changes BEGIN SELECT RAISE(FAIL, 'simulated write failure'); END")

        engine.shutdown()

        XCTAssertEqual(try engine.reader.file(f)?.size, 100, "the failed transaction rolls back file state too")
        XCTAssertEqual(try engine.reader.rows("SELECT v FROM meta WHERE k = 'event_id'") { $0.string(0) }, cursor)
        try engine.reader.exec("DROP TRIGGER fail_changes")
        let recovered = Engine(dataDir: URL(fileURLWithPath: tmp + "/data"))
        recovered.enqueue([f], [UInt32(kFSEventStreamEventFlagItemModified)], [99])
        recovered.waitIdle()
        XCTAssertEqual(try recovered.reader.file(f)?.size, 200)
        XCTAssertEqual(try changes().map(\.kind), [.firstSeen, .grew])
    }

    func testDirectoryRemovalIncludesBufferedFiles() throws {
        let saved = root + "/sub/a.bin", buffered = root + "/sub/z.bin"
        try write(saved, 100)
        engine.addRoot(root)
        engine.waitIdle()
        try engine.check([saved], flags: UInt32(kFSEventStreamEventFlagItemCreated))
        try write(buffered, 200)
        try engine.check([buffered], flags: UInt32(kFSEventStreamEventFlagItemCreated), flush: false)
        try FileManager.default.removeItem(atPath: root + "/sub")
        engine.enqueue([root + "/sub"], [UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsDir)], [1])
        engine.waitIdle()

        XCTAssertNil(try engine.reader.file(saved))
        XCTAssertNil(try engine.reader.file(buffered))
        XCTAssertEqual(try changes().filter { $0.kind == .deleted }.count, 2)
        XCTAssertEqual(try changes().reduce(0) { $0 + $1.newSize - $1.oldSize }, 0)
    }

    func testDeletingBufferedHardLinkKeepsSharedData() throws {
        let f = root + "/f.bin", link = root + "/link.bin"
        try write(f, 100)
        engine.addRoot(root)
        engine.waitIdle()
        try engine.check([f], flags: UInt32(kFSEventStreamEventFlagItemCreated), flush: false)
        XCTAssertEqual(Darwin.link(f, link), 0)
        try engine.check([link], flags: UInt32(kFSEventStreamEventFlagItemCreated), flush: false)
        try FileManager.default.removeItem(atPath: link)
        try engine.check([link], flush: false)
        try write(f, 50, append: true)
        try engine.check([f])

        XCTAssertEqual(try engine.reader.file(f)?.size, 150)
        XCTAssertNil(try engine.reader.file(link))
        XCTAssertEqual(try changes().map(\.kind), [.added])
        XCTAssertEqual(try changes().reduce(0) { $0 + $1.newSize - $1.oldSize }, 150)
        try FileManager.default.removeItem(atPath: f)
        try engine.check([f])
        XCTAssertEqual(try changes().map(\.kind), [.added, .deleted])
        XCTAssertEqual(try changes().reduce(0) { $0 + $1.newSize - $1.oldSize }, 0)
    }

    @MainActor
    func testMenuRefreshesWithMainWindowHidden() async {
        let ready = expectation(description: "initial status published")
        let initialSubscription = engine.$status.dropFirst().prefix(1).sink { _ in ready.fulfill() }
        engine.addRoot(root)
        engine.start()
        engine.waitIdle()
        defer { engine.shutdown() }
        await fulfillment(of: [ready], timeout: 3)
        initialSubscription.cancel()
        engine.windowVisible = false
        engine.menuVisible = true

        let updated = expectation(description: "visible menu receives status")
        let subscription = engine.$status.dropFirst().prefix(1).sink { _ in updated.fulfill() }
        engine.checkTime(Date() + 61)
        await fulfillment(of: [updated], timeout: 3)
        subscription.cancel()
        let revision = engine.status.revision

        engine.menuVisible = false
        let hidden = expectation(description: "hidden views do not refresh")
        hidden.isInverted = true
        let hiddenSubscription = engine.$status.dropFirst().sink { _ in hidden.fulfill() }
        engine.checkTime(Date() + 122)
        await fulfillment(of: [hidden], timeout: 1)
        hiddenSubscription.cancel()
        engine.menuVisible = true
        XCTAssertGreaterThan(engine.status.revision, revision, "reopening the menu immediately publishes the latest snapshot")
    }

    @MainActor
    func testTimeWindowsRefreshWhileIdleAndPaused() async {
        func snapshot(after action: () -> Void) async -> EngineStatus {
            let updated = expectation(description: "status published")
            var result = engine.status
            let subscription = engine.$status.dropFirst().prefix(1).sink { result = $0; updated.fulfill() }
            action()
            await fulfillment(of: [updated], timeout: 3)
            subscription.cancel()
            return result
        }

        let now = Date()
        let initial = await snapshot {
            engine.addRoot(root)
            engine.start()
            engine.waitIdle()
        }
        defer { engine.shutdown() }
        let idle = await snapshot { engine.checkTime(now + 61) }
        XCTAssertGreaterThan(idle.revision, initial.revision, "rolling windows must expire even without new file changes")
        let paused = await snapshot { engine.setPaused(true) }
        XCTAssertTrue(paused.paused)
        let later = await snapshot { engine.checkTime(now + 122) }
        XCTAssertGreaterThan(later.revision, paused.revision, "pausing monitoring must not freeze time-based queries")
    }

    func testFSEventsEndToEnd() throws {
        engine.addRoot(root)   // before start(), which otherwise defaults to the whole disk
        engine.start()
        engine.waitIdle()
        try write(root + "/live.bin", 4096)
        let deadline = Date() + 20
        while Date() < deadline, try changes().isEmpty { usleep(200_000); engine.waitIdle() }
        engine.shutdown()
        XCTAssertEqual(try changes().map(\.kind), [.added])
    }

    func testHotspotsDoNotOverlap() {
        let mb: Int64 = 1 << 20
        let files: [String: Int64] = [
            "/b/dl/big": 1000 * mb, "/a/cache/x/1": 600 * mb, "/a/cache/y/2": 300 * mb,
            "/d/s1": 30 * mb, "/d/s2": 30 * mb, "/d/s3": 30 * mb, "/d/k/f": 200 * mb, "/c/tiny": 10 * mb, "/e/freed": -50 * mb,
        ]
        let (spots, total) = hotspots(files)
        XCTAssertEqual(total, 2200 * mb)
        XCTAssertEqual(spots.map(\.path), ["/b/dl", "/a/cache/x", "/a/cache/y", "/d/k", "/d"])
        XCTAssertEqual(spots.map { $0.net / mb }, [1000, 600, 300, 200, 90], "/d reports only what /d/k does not explain")
        XCTAssertEqual(spots.last?.rest, true)
        XCTAssertEqual(total - spots.reduce(0) { $0 + $1.net }, 10 * mb, "the rest is 其他位置")
        XCTAssertEqual(distinctNames(["/a/x/k", "/b/x/k", "/c/k"]), ["/a/x/k": "a/x/k", "/b/x/k": "b/x/k", "/c/k": "c/k"])
    }

    func testOverviewTotalsMatchRecords() throws {
        let f = root + "/sub/grow.bin", g = root + "/gone.bin"
        try write(f, 100)
        try write(g, 300)
        engine.addRoot(root)
        engine.waitIdle()
        try engine.check([f, g])                 // first seen: not growth
        try write(f, 900, append: true)
        try engine.check([f])
        try FileManager.default.removeItem(atPath: g)
        try engine.check([g])
        let o = try engine.reader.overview(DateInterval(start: Date() - 600, end: Date() + 1))
        XCTAssertEqual(o.growth, 900)
        XCTAssertEqual(o.release, -300)
        XCTAssertEqual(o.net, 600)
        XCTAssertEqual(o.active, 2)
        XCTAssertEqual(o.deleted, 1)
        XCTAssertEqual(o.spots.first?.path, root + "/sub")
        XCTAssertEqual(o.bars.reduce(0) { $0 + $1.value }, 600)
    }

    func testPlacesReadAsOwnerAndRest() {
        let home = NSHomeDirectory()
        XCTAssertEqual(context(of: home + "/Library/Application Support/Dao/extensions_crx_cache"), "Dao › extensions_crx_cache")
        XCTAssertEqual(context(of: home + "/Develop/kindle-dashboard/.cache/kolinux/lib"), "kindle-dashboard › …/kolinux/lib")
        XCTAssertEqual(context(of: "/Volumes/Kindle"), "Kindle")
        XCTAssertEqual(context(of: home + "/Library/Application Support/orca/terminal-history/%2FUsers%2Fx%40%40ab"),
                       "orca › terminal-history/「/Users/x@@ab」")
        XCTAssertEqual(owner(ofDir: home + "/Downloads"), "~/Downloads")
        XCTAssertEqual(ownerName(owner(ofDir: home + "/.claude/projects/x")), ".claude/projects")
        XCTAssertEqual(ownerName(owner(ofDir: "/private/var/folders/0l/abc/T")), "系统临时目录")
    }

    func testCoverageGaps() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let range = DateInterval(start: t0, duration: 100)
        let gaps = coverageGaps(range, [DateInterval(start: t0 + 10, duration: 20), DateInterval(start: t0 + 50, end: .distantFuture)])
        XCTAssertEqual(gaps, [DateInterval(start: t0, duration: 10), DateInterval(start: t0 + 30, duration: 20)])
        XCTAssertEqual(coverageGaps(range, []), [range])
    }
}
