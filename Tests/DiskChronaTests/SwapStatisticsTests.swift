import XCTest
@testable import DiskChrona

final class SwapStatisticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var interval: DateInterval { DateInterval(start: now - 3600, end: now) }

    private func fixture() throws -> DB {
        let db = try DB(path: ":memory:")
        try db.migrate()
        let rows: [(String, Kind, Int, Int, Int, Int)] = [
            ("/System/Volumes/VM/swapfile0", .added, 0, 1000, 0, 2000),
            ("/private/var/vm/swapfile1", .added, 0, 1000, 0, 2000),
            ("/var/vm/swapfile2", .added, 0, 1000, 0, 2000),
            ("/System/Volumes/Data/private/var/vm/swapfile3", .added, 0, 1000, 0, 2000),
            ("/System/Volumes/Data/var/vm/swapfile4", .added, 0, 1000, 0, 2000),
            ("/System/Volumes/VM/swapfile0", .deleted, 1000, 0, 2000, 0),
            ("/work/file.bin", .grew, 100, 300, 100, 400),
            ("/work/gone.bin", .deleted, 50, 0, 80, 0),
            ("/System/Volumes/VM/sleepimage", .added, 0, 30, 0, 60),
            ("/System/Volumes/VM/swapfile1.bak", .added, 0, 20, 0, 40),
            ("/work/swapfile1", .added, 0, 10, 0, 20),
        ]
        for (path, kind, old, new, oldAlloc, newAlloc) in rows {
            try db.run("INSERT INTO changes(ts_prev, ts, path, kind, old_size, new_size, old_alloc, new_alloc) VALUES(?, ?, ?, ?, ?, ?, ?, ?)",
                       [now.timeIntervalSince1970 - 20, now.timeIntervalSince1970 - 10, path, kind.rawValue, old, new, oldAlloc, newAlloc])
        }
        try db.run("INSERT INTO volume(ts, free) VALUES(?, 10000), (?, 6000)", [now.timeIntervalSince1970 - 120, now.timeIntervalSince1970])
        return db
    }

    func testOverviewExcludesSwapFromEveryAggregateButKeepsHistoryAndFreeSpace() throws {
        let db = try fixture()
        let all = try db.overview(interval)
        XCTAssertEqual(all.net, 4210)
        let filtered = try db.overview(interval, ignoreSwap: true)
        XCTAssertEqual(filtered.growth, 260)
        XCTAssertEqual(filtered.release, -50)
        XCTAssertEqual(filtered.net, 210)
        XCTAssertEqual(filtered.localNet, 210)
        XCTAssertEqual(filtered.active, 5)
        XCTAssertEqual(filtered.added, 3)
        XCTAssertEqual(filtered.deleted, 1)
        XCTAssertEqual(filtered.total, 260)
        XCTAssertEqual(filtered.bars.reduce(0) { $0 + $1.value }, 210)
        XCTAssertEqual(Set(filtered.files.map(\.path)), Set(["/work/file.bin", "/work/swapfile1", "/System/Volumes/VM/sleepimage", "/System/Volumes/VM/swapfile1.bak"]))
        XCTAssertEqual(filtered.free.map(\.free), all.free.map(\.free))
        XCTAssertEqual(filtered.freeDelta, -4000)
        XCTAssertEqual(try db.timeline(interval, search: "", limit: 100).count, 11)
        XCTAssertEqual(try db.history("/System/Volumes/VM/swapfile0").count, 2)
        XCTAssertEqual(try db.overview(interval, ignoreSwap: false).net, 4210)
    }

    func testRankingFiltersBeforeGroupingForBothMetricsAndPreservesSearch() throws {
        let db = try fixture()
        for metric in Metric.allCases {
            for byDir in [false, true] {
                for sort in RankSort.allCases {
                    let rows = try db.ranking(interval, metric: metric, sort: sort, search: "", byDir: byDir, dir: "/", ignoreSwap: true)
                    XCTAssertEqual(rows.reduce(0) { $0 + $1.net }, metric == .size ? 210 : 340)
                    XCTAssertEqual(rows.reduce(0) { $0 + $1.growth }, metric == .size ? 260 : 420)
                }
            }
        }
        let searched = try db.ranking(interval, metric: .size, sort: .growth, search: "swapfile", byDir: false, dir: "/", ignoreSwap: true)
        XCTAssertEqual(Set(searched.map(\.path)), Set(["/work/swapfile1", "/System/Volumes/VM/swapfile1.bak"]))
        let vm = try db.ranking(interval, metric: .size, sort: .growth, search: "", byDir: true, dir: "/System/Volumes/VM", ignoreSwap: true)
        XCTAssertEqual(Set(vm.map(\.name)), Set(["sleepimage", "swapfile1.bak"]))
    }

    func testLiveGroupsAndRateUseTheSameSwapFilter() throws {
        let db = try fixture()
        XCTAssertEqual(try db.live(now).rate, 5260)
        let filtered = try db.live(now, ignoreSwap: true)
        XCTAssertEqual(filtered.rate, 260)
        XCTAssertEqual(filtered.groups.reduce(0) { $0 + $1.net }, 210)
        XCTAssertEqual(filtered.groups.reduce(0) { $0 + $1.growth }, 260)
        XCTAssertEqual(filtered.groups.reduce(0) { $0 + $1.files }, 5)
    }

    func testRateCanToggleSwapWithoutLosingSamplesAndExpiresBothKinds() {
        var meter = RateMeter()
        meter.add(1000, at: 1000, isSwap: true)
        meter.add(100, at: 1000)
        meter.add(-300, at: 1030, isSwap: true)
        meter.add(-20, at: 1030)
        XCTAssertEqual(meter.sum(at: 1059), 780)
        XCTAssertEqual(meter.sum(at: 1059, ignoreSwap: true), 80)
        XCTAssertEqual(meter.sum(at: 1059), 780)
        XCTAssertEqual(meter.sum(at: 1060, ignoreSwap: true), -20)
        meter.add(5, at: 1060)
        XCTAssertEqual(meter.sum(at: 1060, ignoreSwap: true), -15)
        XCTAssertEqual(meter.sum(at: 1060), -315)
        XCTAssertEqual(meter.sum(at: 1090, ignoreSwap: true), 5)
        XCTAssertEqual(meter.sum(at: 1120), 0)
    }

    @MainActor
    func testPreferenceSurvivesReopeningAndCanBeDisabledAgain() throws {
        let suite = "DiskChronaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let dataDir = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dataDir)
        }
        let engine = Engine(dataDir: dataDir, defaults: defaults)
        XCTAssertFalse(engine.ignoreSwap)
        engine.ignoreSwap = true
        let reopened = Engine(dataDir: dataDir, defaults: defaults)
        XCTAssertTrue(reopened.ignoreSwap)
        reopened.ignoreSwap = false
        XCTAssertFalse(Engine(dataDir: dataDir, defaults: defaults).ignoreSwap)
    }
}
