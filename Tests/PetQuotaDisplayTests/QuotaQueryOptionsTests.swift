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
        let history = try QuotaQueryOptions(arguments: ["--provider", "codex", "--account", "Work"], purpose: .savedHistory)
        XCTAssertEqual(history.account, "Work")
        XCTAssertThrowsError(try QuotaQueryOptions(arguments: ["--timeout", "1"], purpose: .savedHistory))
    }
}
