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

    func testMissingStringValueDoesNotConsumeTheNextFlag() {
        XCTAssertThrowsError(try QuotaQueryOptions(arguments: ["--account", "--format", "csv"])) {
            XCTAssertEqual($0.localizedDescription, "--account 缺少参数值。")
        }
        XCTAssertThrowsError(try QuotaQueryOptions(arguments: ["--model", "--require-fresh"])) {
            XCTAssertEqual($0.localizedDescription, "--model 缺少参数值。")
        }
        XCTAssertThrowsError(try QuotaQueryOptions(arguments: ["--invalid"], purpose: .savedHistory)) {
            XCTAssertTrue($0.localizedDescription.contains("--history --help"))
        }
    }

    func testModelListRejectsIncompatibleOptions() throws {
        XCTAssertTrue(try QuotaQueryOptions(arguments: ["--list-models", "--account", "Work", "--format", "text"]).listModels)
        XCTAssertThrowsError(try QuotaQueryOptions(arguments: ["--list-models", "--provider", "gemini"]))
        XCTAssertThrowsError(try QuotaQueryOptions(arguments: ["--list-models", "--period", "weekly"]))
    }

    func testLiveBatchAcceptsAnAccountButRejectsSingleProviderOptions() throws {
        let batch = try QuotaQueryOptions(arguments: ["--all", "--account", "Work", "--period", "weekly"])
        XCTAssertEqual(batch.batchProviders, QuotaProvider.allCases)
        XCTAssertEqual(batch.account, "Work")
        XCTAssertEqual(batch.period, "weekly")
        XCTAssertThrowsError(try QuotaQueryOptions(arguments: ["--all", "--provider", "codex"]))
        XCTAssertThrowsError(try QuotaQueryOptions(arguments: ["--all", "--list-models"]))
        XCTAssertEqual(try QuotaQueryOptions(arguments: ["--all"], purpose: .savedHistory).batchProviders,
                       QuotaProvider.allCases)
    }

    func testBatchCanSelectAnOrderedSetOfProviders() throws {
        let batch = try QuotaQueryOptions(arguments: ["--providers", "gemini, kimiCode"])
        XCTAssertEqual(batch.batchProviders, [.gemini, .kimiCode])
        XCTAssertThrowsError(try QuotaQueryOptions(arguments: ["--providers", "gemini,gemini"]))
        XCTAssertThrowsError(try QuotaQueryOptions(arguments: ["--providers", "gemini,"]))
        XCTAssertThrowsError(try QuotaQueryOptions(arguments: ["--providers", "gemini", "--account", "Work"]))
        XCTAssertThrowsError(try QuotaQueryOptions(arguments: ["--providers", "gemini", "--all"]))
        XCTAssertTrue(try QuotaQueryOptions(arguments: ["--all", "--include-models"], purpose: .savedHistory).includesModels)
        XCTAssertThrowsError(try QuotaQueryOptions(arguments: ["--providers", "gemini", "--include-models"], purpose: .savedHistory))
        XCTAssertThrowsError(try QuotaQueryOptions(arguments: ["--all", "--include-models"]))
    }

    func testSavedHistoryRejectsLiveQueryOptions() throws {
        let history = try QuotaQueryOptions(arguments: ["--provider", "codex", "--account", "Work",
                                                        "--model", "extra", "--format", "csv"], purpose: .savedHistory)
        XCTAssertEqual(history.account, "Work")
        XCTAssertEqual(history.modelID, "extra")
        XCTAssertEqual(history.format, .csv)
        XCTAssertTrue(try QuotaQueryOptions(arguments: ["--list-models"], purpose: .savedHistory).listModels)
        XCTAssertThrowsError(try QuotaQueryOptions(arguments: ["--list-models", "--limit", "10"], purpose: .savedHistory))
        XCTAssertEqual(try QuotaQueryOptions(arguments: ["--limit", "3"], purpose: .savedHistory).limit, 3)
        XCTAssertThrowsError(try QuotaQueryOptions(arguments: ["--limit", "0"], purpose: .savedHistory))
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
