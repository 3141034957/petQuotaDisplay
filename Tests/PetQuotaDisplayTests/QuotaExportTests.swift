import QuotaCore
import XCTest
@testable import PetQuotaDisplay

final class QuotaExportTests: XCTestCase {
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
