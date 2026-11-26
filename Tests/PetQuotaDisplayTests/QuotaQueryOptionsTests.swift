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
        XCTAssertTrue(try QuotaQueryOptions(arguments: ["--require-fresh", "--provider", "claudeCode"]).requireFresh)
        XCTAssertEqual(try QuotaQueryOptions(arguments: ["--model", "extra"]).modelID, "extra")
    }

    func testRejectsUnsupportedFlagsAndInvalidValues() throws {
        for arguments in [["--always-show"], ["--timeout"], ["--timeout", "0"], ["--timeout", "3601"],
                          ["--timeout", "1", "--timeout", "2"], ["--period", "yearly"], ["--provider", "typo"],
                          ["--format", "markdown"], ["--fail-below", "101"], ["--require-fresh", "--require-fresh"]] {
            XCTAssertThrowsError(try QuotaQueryOptions(arguments: arguments), arguments.joined(separator: " "))
        }
    }

    func testModelListRejectsIncompatibleOptions() throws {
        XCTAssertTrue(try QuotaQueryOptions(arguments: ["--list-models", "--account", "Work", "--format", "text"]).listModels)
        XCTAssertThrowsError(try QuotaQueryOptions(arguments: ["--list-models", "--provider", "gemini"]))
        XCTAssertThrowsError(try QuotaQueryOptions(arguments: ["--list-models", "--period", "weekly"]))
    }

    func testSavedHistoryRejectsLiveQueryOptions() throws {
        let history = try QuotaQueryOptions(arguments: ["--provider", "codex", "--account", "Work", "--format", "csv"], purpose: .savedHistory)
        XCTAssertEqual(history.account, "Work")
        XCTAssertEqual(history.format, .csv)
        XCTAssertThrowsError(try QuotaQueryOptions(arguments: ["--timeout", "1"], purpose: .savedHistory))
    }

    func testHistoryDateRangeAcceptsISO8601AndRejectsReversedBounds() throws {
        let options = try QuotaQueryOptions(arguments: ["--since", "1970-01-01T08:01:00+08:00",
                                                       "--until", "1970-01-01T00:02:00Z"], purpose: .savedHistory)
        XCTAssertEqual(options.since, Date(timeIntervalSince1970: 60))
        XCTAssertEqual(options.until, Date(timeIntervalSince1970: 120))
        XCTAssertThrowsError(try QuotaQueryOptions(arguments: ["--since", "bad"], purpose: .savedHistory))
        XCTAssertThrowsError(try QuotaQueryOptions(arguments: ["--since", "1970-01-01T00:02:00Z",
                                                                "--until", "1970-01-01T00:01:00Z"], purpose: .savedHistory))
    }
}
