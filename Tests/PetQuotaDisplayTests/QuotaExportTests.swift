import QuotaCore
import XCTest
@testable import PetQuotaDisplay

final class QuotaExportTests: XCTestCase {
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
