import XCTest
@testable import PetQuotaDisplay

final class QuotaQueryOptionsTests: XCTestCase {
    func testParsesQueryOptionsInAnyOrder() throws {
        let options = try QuotaQueryOptions(arguments: ["--timeout", "5", "--period", "weekly", "--provider", "gemini"])
        XCTAssertEqual(options.provider, .gemini)
        XCTAssertEqual(options.period, "weekly")
        XCTAssertEqual(options.timeout, 5)
        XCTAssertEqual(try QuotaQueryOptions(arguments: []).timeout, 65)
        XCTAssertEqual(try QuotaQueryOptions(arguments: []).format, .json)
        XCTAssertEqual(try QuotaQueryOptions(arguments: ["--format", "text"]).format, .text)
        XCTAssertEqual(try QuotaQueryOptions(arguments: ["--fail-below", "20"]).failBelow, 20)
    }

    func testRejectsUnsupportedFlagsAndInvalidValues() throws {
        for arguments in [["--always-show"], ["--timeout"], ["--timeout", "0"], ["--timeout", "3601"],
                          ["--timeout", "1", "--timeout", "2"], ["--period", "yearly"], ["--provider", "typo"],
                          ["--format", "markdown"], ["--fail-below", "101"]] {
            XCTAssertThrowsError(try QuotaQueryOptions(arguments: arguments), arguments.joined(separator: " "))
        }
    }
}
