import XCTest
@testable import DiskChrona

final class AnalysisPromptTests: XCTestCase {
    func testPromptPreservesDatabasePathAndSelectedRangeForTheAgent() throws {
        let path = "/tmp/分析 \"资料\"/DiskChrona.sqlite"
        let interval = DateInterval(start: Date(timeIntervalSince1970: 1_800_000_000), duration: 3600)
        for ignoreSwap in [false, true] {
            let prompt = try analysisPrompt(databasePath: path, interval: interval, ignoreSwap: ignoreSwap)
            let json = try XCTUnwrap(prompt.components(separatedBy: "```json\n").dropFirst().first?.components(separatedBy: "\n```").first)
            let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertEqual(context["databasePath"] as? String, path)
            XCTAssertEqual(context["startUnixSeconds"] as? Double, 1_800_000_000)
            XCTAssertEqual(context["endUnixSeconds"] as? Double, 1_800_003_600)
            XCTAssertEqual(context["ignoreSwap"] as? Bool, ignoreSwap)
            XCTAssertNotNil((context["timeZone"] as? String).flatMap(TimeZone.init(identifier:)))
        }
    }
}
