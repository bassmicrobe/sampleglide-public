import XCTest
@testable import SampleBrowser

final class SearchQueryTests: XCTestCase {
    private func bpmFilters(minimum: Double?, maximum: Double?) throws -> [[String:Any]] {
        let body = try APIClient.searchBody(text: "", favorite: false, bpmMinimum: minimum, bpmMaximum: maximum, kind: "all", sort: "name", cursor: nil)
        let filter = try XCTUnwrap(body["filter"] as? [String:Any])
        return try XCTUnwrap(filter["all"] as? [[String:Any]])
    }
    func testOneSidedAndCompleteBPMFilters() throws {
        let lower = try bpmFilters(minimum: 120, maximum: nil)
        XCTAssertEqual(lower.count, 1)
        XCTAssertEqual(lower[0]["field"] as? String, "bpm")
        XCTAssertEqual(lower[0]["op"] as? String, "gte")
        XCTAssertEqual(lower[0]["value"] as? Double, 120)
        let upper = try bpmFilters(minimum: nil, maximum: 140)
        XCTAssertEqual(upper.count, 1)
        XCTAssertEqual(upper[0]["op"] as? String, "lte")
        XCTAssertEqual(upper[0]["value"] as? Double, 140)
        let both = try bpmFilters(minimum: 120, maximum: 140)
        XCTAssertEqual(both[0]["op"] as? String, "between")
        XCTAssertEqual(both[0]["value"] as? [Double], [120,140])
        XCTAssertTrue(try bpmFilters(minimum: nil, maximum: nil).isEmpty)
    }
    func testInvalidBPMCannotBecomeAnUnfilteredRequest() throws {
        XCTAssertNil(try APIClient.parseBPMBound("  "))
        XCTAssertEqual(try APIClient.parseBPMBound(" 120.5 "), 120.5)
        for text in ["abc", "NaN", "inf", "-inf", "0", "-120"] {
            XCTAssertThrowsError(try APIClient.parseBPMBound(text), text)
        }
        for value in [Double.nan, Double.infinity, -Double.infinity, 0, -120] {
            XCTAssertThrowsError(try bpmFilters(minimum: value, maximum: nil))
            XCTAssertThrowsError(try bpmFilters(minimum: nil, maximum: value))
        }
        XCTAssertThrowsError(try bpmFilters(minimum: 140, maximum: 120))
    }
}
