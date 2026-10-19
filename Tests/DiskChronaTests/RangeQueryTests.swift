import XCTest
@testable import DiskChrona

@MainActor
final class RangeQueryTests: XCTestCase {
    func testDirectoryChangeShowsLoadingUntilNewRowsArrive() async {
        let query = RangeQuery(["old row"])
        let range = TimeRange(span: .today)
        let parent: [AnyHashable] = [range, true, "/"]
        let child: [AnyHashable] = [range, true, "/Users"]
        await query.load(parent) { ["old row"] }
        XCTAssertFalse(query.isLoading(parent))
        XCTAssertTrue(query.isLoading(child))

        let started = expectation(description: "Directory query started")
        var finish: CheckedContinuation<[String]?, Never>?
        let task = Task {
            await query.load(child) {
                await withCheckedContinuation { finish = $0; started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(query.isLoading(child))
        XCTAssertEqual(query.value, ["old row"])
        finish?.resume(returning: ["new row"])
        await task.value

        XCTAssertFalse(query.isLoading(child))
        XCTAssertEqual(query.value, ["new row"])
        XCTAssertTrue(query.isLoading(parent))
    }

    func testRangeChangeImmediatelyNeedsLoadingAndBypassesRefreshThrottle() async {
        let query = RangeQuery(0)
        let today = TimeRange(span: .today)
        let hour = TimeRange(span: .hour)
        XCTAssertTrue(query.isLoading(today))
        await query.load(today) { 1 }
        XCTAssertFalse(query.isLoading(today))
        XCTAssertTrue(query.isLoading(hour))

        let fetched = expectation(description: "New range does not wait for refresh throttle")
        let task = Task {
            await query.load(hour, throttle: 60) { fetched.fulfill(); return 2 }
        }
        await fulfillment(of: [fetched], timeout: 1)
        task.cancel()
        await task.value
        XCTAssertEqual(query.value, 2)
        XCTAssertFalse(query.isLoading(hour))
    }

    func testCancelledOldQueryCannotOverwriteNewRange() async {
        let query = RangeQuery(0)
        let today = TimeRange(span: .today)
        let hour = TimeRange(span: .hour)
        let started = expectation(description: "Old query started")
        var finish: CheckedContinuation<Int?, Never>?
        let old = Task {
            await query.load(today) {
                await withCheckedContinuation { finish = $0; started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 1)
        old.cancel()
        await query.load(hour) { 2 }
        finish?.resume(returning: 1)
        await old.value
        XCTAssertEqual(query.value, 2)
        XCTAssertFalse(query.isLoading(hour))
    }

    func testBackgroundRefreshKeepsDataVisibleAndHonorsThrottleCancellation() async {
        let query = RangeQuery(0)
        let range = TimeRange()
        await query.load(range) { 1 }
        let task = Task {
            await query.load(range, throttle: 60) {
                XCTFail("Cancelled throttled refresh must not query")
                return 2
            }
        }
        await Task.yield()
        XCTAssertFalse(query.isLoading(range))
        XCTAssertEqual(query.value, 1)
        task.cancel()
        await task.value
        XCTAssertEqual(query.value, 1)
    }

    func testFailureEndsLoadingAndNextQueryRecovers() async {
        let query = RangeQuery(0)
        let range = TimeRange()
        await query.load(range) { nil }
        XCTAssertFalse(query.isLoading(range))
        XCTAssertTrue(query.failed)
        await query.load(range) { 3 }
        XCTAssertFalse(query.failed)
        XCTAssertEqual(query.value, 3)
    }
}
