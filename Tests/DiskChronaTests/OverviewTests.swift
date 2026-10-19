import XCTest
@testable import DiskChrona

final class OverviewTests: XCTestCase {
    func testSystemFileTagsRecognizeSwapAcrossSystemPaths() {
        for root in ["/System/Volumes/VM", "/private/var/vm", "/var/vm", "/System/Volumes/Data/private/var/vm"] {
            for name in ["swapfile0", "swapfile22", "swapfile23"] {
                XCTAssertEqual(locationTag(root + "/" + name), "Swap", root + "/" + name)
            }
            XCTAssertEqual(locationTag(root), "Virtual memory")
            XCTAssertEqual(locationTag(root + "/sleepimage"), "Sleep image")
            XCTAssertEqual(locationTag(root + "/swapfile22.bak"), "Virtual memory")
            XCTAssertEqual(locationTag(root + "/swapfile"), "Virtual memory")
        }
    }

    func testSystemFileTagsPreferSpecificPurposeOverGenericLocation() {
        let cases = [
            ("/.Spotlight-V100/Store-V2/store.db", "Search index"),
            ("/System/Volumes/Data/.Spotlight-V100/Store-V2/store.db", "Search index"),
            ("/Volumes/External Disk/.Spotlight-V100/Store-V2/store.db", "Search index"),
            ("/.fseventsd/00000001", "FSEvents log"),
            ("/Volumes/External Disk/.fseventsd/00000001", "FSEvents log"),
            ("/private/var/db/diagnostics/Persist/0001.tracev3", "System logs"),
            ("/var/db/uuidtext/00/ABC", "System logs"),
            ("/System/Volumes/Data/private/var/db/diagnostics", "System logs"),
            ("/Library/Logs/DiagnosticReports/app.ips", "Diagnostic reports"),
            (NSHomeDirectory() + "/Library/Logs/DiagnosticReports/app.ips", "Diagnostic reports"),
            ("/Library/Updates/update.pkg", "System updates"),
        ]
        for (path, tag) in cases { XCTAssertEqual(locationTag(path), tag, path) }
    }

    func testSystemFileTagsDoNotMislabelOrdinaryFilesOrSimilarPaths() {
        for path in [
            "/work/swapfile22", "/work/sleepimage", "/work/private/var/vm/swapfile23",
            "/System/Volumes/VM-copy/swapfile22", "/private/var/vm-old/swapfile23",
            "/work/.Spotlight-V100/store.db", "/Volumes/External/project/.fseventsd/log",
            "/work/Library/Updates/update.pkg",
        ] {
            XCTAssertNil(locationTag(path), path)
        }
        XCTAssertEqual(locationTag("/private/var/db/diagnostics-copy/data"), "System data")
        XCTAssertEqual(locationTag(NSHomeDirectory() + "/Downloads/swapfile22"), "Downloads")
        XCTAssertEqual(locationTag(NSHomeDirectory() + "/Library/Caches/cache.db"), "Caches")
    }

    func testFreeSpaceHoverSelectsAnExistingPointWithoutInterpolating() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var data = Overview()
        XCTAssertNil(data.freePoint(near: start))
        data.free = [.init(t: start, free: 70_000_000_000), .init(t: start + 600, free: 63_000_000_000)]
        let selected = try XCTUnwrap(data.freePoint(near: start + 400))
        XCTAssertEqual(selected.t, start + 600)
        XCTAssertEqual(selected.free, 63_000_000_000)
        XCTAssertEqual(data.freePoint(near: start + 300)?.t, start, "Equal distances prefer the earlier point")
        XCTAssertEqual(data.freePoint(near: start - 60)?.t, start)
        XCTAssertEqual(data.freePoint(near: start + 900)?.t, start + 600)
        data.free.removeLast()
        XCTAssertEqual(data.freePoint(near: start + 400)?.t, start)
    }
}
