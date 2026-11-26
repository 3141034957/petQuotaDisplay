import QuotaCore
import XCTest
@testable import PetQuotaDisplay

final class QuotaExportTests: XCTestCase {
    func testCodexQueryCanSelectNamedModelsWithoutFallingBackOnTypos() throws {
        let report = try QuotaParser.parseReport(result: [
            "rateLimits": ["limitId": "primary-model", "primary": ["usedPercent": 20, "windowDurationMins": 300]],
            "rateLimitsByLimitId": ["extra": ["primary": ["usedPercent": 50, "windowDurationMins": 300]]],
        ])
        let primary = try QuotaQuery.codexExport(from: report, modelID: "primary-model")
        XCTAssertNil(primary.codexLimitID)
        XCTAssertEqual(primary.periods.first?.remainingPercent, 80)
        let extra = try QuotaQuery.codexExport(from: report, modelID: "extra")
        XCTAssertEqual(extra.codexLimitID, "extra")
        XCTAssertEqual(extra.periods.first?.remainingPercent, 50)
        XCTAssertThrowsError(try QuotaQuery.codexExport(from: report, modelID: "typo"))
        let catalog = CodexModelCatalog(report)
        XCTAssertEqual(catalog.models.map(\.id), ["primary-model", "extra"])
        XCTAssertEqual(catalog.models.map(\.isPrimary), [true, false])
        XCTAssertEqual(catalog.models.map(\.periods), [["fiveHour"], ["fiveHour"]])
    }

    func testLowQuotaStatusUsesTheExportedWindowsAndStrictThreshold() throws {
        let snapshot = QuotaSnapshot(planType: nil,
                                     fiveHour: QuotaWindow(usedPercent: 95, resetsAt: nil),
                                     weekly: QuotaWindow(usedPercent: 80, resetsAt: nil))
        var export = try XCTUnwrap(QuotaExport(provider: .gemini, state: .loaded(snapshot)))
        XCTAssertEqual(export.exitStatus(failBelow: nil), 0)
        XCTAssertEqual(export.exitStatus(failBelow: 10), 2)
        try export.selectPeriod("weekly")
        XCTAssertEqual(export.exitStatus(failBelow: 20), 0)
        XCTAssertEqual(export.exitStatus(failBelow: 21), 2)
    }

    func testBatchPreservesSuccessfulSourcesAndOmitsRawServiceDetails() throws {
        let snapshot = QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 90, resetsAt: nil),
                                    fetchedAt: Date(timeIntervalSince1970: 60))
        let quota = try XCTUnwrap(QuotaExport(provider: .gemini, state: .stale(snapshot, "old")))
        let gemini = QuotaBatchExport.Source(provider: .gemini, result: .success(quota))
        let codex = QuotaBatchExport.Source(provider: .codex, result: .failure(CodexQuotaClient.ClientError.server("server details")))
        let partial = QuotaBatchExport(sources: [codex, gemini])
        XCTAssertEqual(partial.exitStatus(failBelow: 20, requireFresh: true), 1)
        XCTAssertEqual(QuotaBatchExport(sources: [gemini]).exitStatus(failBelow: 20, requireFresh: true), 3)
        XCTAssertEqual(QuotaBatchExport(sources: [gemini]).exitStatus(failBelow: 20, requireFresh: false), 2)

        let report = try partial.render(as: .json)
        XCTAssertTrue(report.contains("Codex 服务无法返回额度"))
        XCTAssertFalse(report.contains("server details"))
        XCTAssertEqual(try partial.render(as: .csv), """
        provider,codexLimitID,status,fetchedAt,period,remainingPercent,resetsAt,error
        codex,,,,,,,Codex 服务无法返回额度
        gemini,,stale,1970-01-01T00:01:00Z,weekly,10,,
        """)
    }

    func testCSVOutputEscapesModelIDAndLeavesUnknownResetEmpty() throws {
        let window = QuotaWindow(usedPercent: 25, resetsAt: nil)
        let snapshot = QuotaSnapshot(planType: nil, fiveHour: window, weekly: nil, fetchedAt: Date(timeIntervalSince1970: 60))
        let model = CodexMeteredQuota(id: "model, \"tier\"", name: "Model", snapshot: snapshot)
        let export = try XCTUnwrap(QuotaExport(provider: .codex, state: .loaded(snapshot), model: model))
        XCTAssertEqual(try export.render(as: .csv), #"""
        provider,codexLimitID,status,fetchedAt,period,remainingPercent,resetsAt
        codex,"model, ""tier""",current,1970-01-01T00:01:00Z,fiveHour,75,
        """#)
    }

    func testTextOutputLabelsStaleResultsAndFormatsResetInUTC() throws {
        let window = QuotaWindow(usedPercent: 35, resetsAt: Date(timeIntervalSince1970: 120))
        let snapshot = QuotaSnapshot(planType: nil, fiveHour: nil, weekly: window, fetchedAt: Date(timeIntervalSince1970: 60))
        let export = try XCTUnwrap(QuotaExport(provider: .claudeCode, state: .stale(snapshot, "details")))
        XCTAssertEqual(export.exitStatus(failBelow: 70, requireFresh: true), 3)
        XCTAssertEqual(export.exitStatus(failBelow: 70), 2)
        XCTAssertEqual(try export.render(as: .text), """
        Claude Code · 上次结果
        采集时间 1970-01-01T00:01:00Z
        本周剩余 65% · 重置时间 1970-01-01T00:02:00Z
        """)
    }

    func testQueryCanSelectOnePeriodAndReportsMissingPeriod() throws {
        let window = QuotaWindow(usedPercent: 80, resetsAt: nil)
        let snapshot = QuotaSnapshot(planType: nil, fiveHour: window, weekly: window)
        let original = try XCTUnwrap(QuotaExport(provider: .gemini, state: .loaded(snapshot)))
        var filtered = original
        try filtered.selectPeriod("fiveHour")
        XCTAssertEqual(filtered.periods.map(\.id), ["fiveHour"])

        filtered = original
        try filtered.selectPeriod("lowestRemaining")
        XCTAssertEqual(filtered.periods.map(\.id), ["weekly"])
        XCTAssertThrowsError(try filtered.selectPeriod("monthly"))
    }
}
