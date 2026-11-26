import QuotaCore
import XCTest
@testable import PetQuotaDisplay

final class QuotaHistorySeriesTests: XCTestCase {
    func testTrendBreaksAtMissingWindowsAndChangedResetTimes() {
        let firstReset = Date(timeIntervalSince1970: 100)
        let secondReset = Date(timeIntervalSince1970: 200)
        let windows: [QuotaWindow?] = [
            QuotaWindow(usedPercent: 40, resetsAt: firstReset),
            QuotaWindow(usedPercent: 50, resetsAt: nil),
            QuotaWindow(usedPercent: 5, resetsAt: secondReset),
            nil,
            QuotaWindow(usedPercent: 25, resetsAt: secondReset),
        ]
        let readings = windows.enumerated().map { index, window in
            QuotaSnapshot(planType: nil, fiveHour: nil, weekly: window,
                          fetchedAt: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        let chart = QuotaHistorySeries(readings: readings, period: .weekly)
        XCTAssertEqual(chart.points.map(\.segment), [0, 0, 1, 2])
        XCTAssertEqual(chart.points.map(\.remainingPercent), [60, 50, 95, 75])
        let nearest = chart.nearestPoint(to: Date(timeIntervalSince1970: 2.25))
        XCTAssertEqual(nearest?.remainingPercent, 95)
        XCTAssertEqual(nearest?.resetsAt, secondReset)
    }
}
