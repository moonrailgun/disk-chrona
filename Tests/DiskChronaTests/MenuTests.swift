import SwiftUI
import XCTest
@testable import DiskChrona

final class MenuTests: XCTestCase {
    func testHoverAggregatesOnlyTheSelectedMinute() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var data = Overview()
        data.interval = DateInterval(start: start, duration: 3600)
        data.bars = [
            .init(id: 0, start: start, series: "A", value: 4_000),
            .init(id: 1, start: start, series: "B", value: 6_000),
            .init(id: 2, start: start, series: Overview.releaseKey, value: -3_000),
            .init(id: 3, start: start + 60, series: "A", value: 99_000),
        ]
        let bucket = try XCTUnwrap(MenuBucket(data: data, date: start + 59, gaps: []))
        XCTAssertEqual(bucket.interval, DateInterval(start: start, duration: 60))
        XCTAssertEqual(bucket.growth, 10_000)
        XCTAssertEqual(bucket.release, 3_000)
        XCTAssertEqual(bucket.net, 7_000)
        XCTAssertFalse(bucket.hasGap)
        XCTAssertEqual(MenuBucket(data: data, date: start + 60, gaps: [])?.growth, 99_000)
    }

    func testHoverDistinguishesQuietMinutesFromMonitoringGaps() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var data = Overview()
        data.interval = DateInterval(start: start + 20, duration: 180)
        let oldGap = DateInterval(start: start - 60, end: start + 20)
        let quiet = try XCTUnwrap(MenuBucket(data: data, date: start + 30, gaps: [oldGap]))
        XCTAssertEqual(quiet.net, 0)
        XCTAssertFalse(quiet.hasGap, "a gap outside the displayed range must not mark this minute as incomplete")
        let gap = DateInterval(start: start + 70, duration: 5)
        XCTAssertTrue(try XCTUnwrap(MenuBucket(data: data, date: start + 65, gaps: [gap])).hasGap)
        XCTAssertFalse(try XCTUnwrap(MenuBucket(data: data, date: start + 120, gaps: [gap])).hasGap)
        XCTAssertNil(MenuBucket(data: data, date: start + 19, gaps: []))
        XCTAssertNil(MenuBucket(data: data, date: data.interval.end, gaps: []))
    }

    @MainActor func testCompactLabelRendersAtMenuBarHeight() throws {
        for rate: Int64 in [0, 3_800_000, -7_100_000, 121_600_000, 999_000_000_000] {
            let image = try XCTUnwrap(MenuRateLabel(rate: rate).image)
            XCTAssertTrue(image.isTemplate)
            XCTAssertLessThan(image.size.width, 50)
            XCTAssertEqual(image.size.height, 22)
        }
    }
}
