import QuotaCore
import XCTest
@testable import PetQuotaDisplay

final class QuotaHistorySeriesTests: XCTestCase {
    func testTimeRangeUsesTheLatestCaptureAndIncludesTheBoundary() {
        let readings = [0.0, 2_699, 2_700, 3_600].map { time in
            QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 30, resetsAt: nil),
                          fetchedAt: Date(timeIntervalSince1970: time))
        }
        let recent = QuotaHistorySeries(readings: readings, period: .weekly, range: .quarterHour)
        XCTAssertEqual(recent.points.map { $0.time.timeIntervalSince1970 }, [2_700, 3_600])
        let first = Date(timeIntervalSince1970: 2_700)
        XCTAssertNil(recent.point(adjacentTo: first, offset: -1))
        XCTAssertEqual(recent.point(adjacentTo: first, offset: 1)?.time, readings.last?.fetchedAt)
        XCTAssertEqual(QuotaHistorySeries(readings: readings, period: .weekly, range: .hour).points.count, 4)
    }

    func testLongerRangesUseTheLastCaptureRatherThanTheCurrentTime() {
        let latest = 8.0 * 24 * 3_600
        let times = [0, latest - 7 * 24 * 3_600, latest - 24 * 3_600, latest - 6 * 3_600, latest]
        let readings = times.map { time in
            QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 30, resetsAt: nil),
                          fetchedAt: Date(timeIntervalSince1970: time))
        }
        XCTAssertEqual(QuotaHistorySeries(readings: readings, period: .weekly, range: .sixHours).points.count, 2)
        XCTAssertEqual(QuotaHistorySeries(readings: readings, period: .weekly, range: .day).points.count, 3)
        XCTAssertEqual(QuotaHistorySeries(readings: readings, period: .weekly, range: .week).points.count, 4)
    }

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
        XCTAssertEqual(chart.points.map(\.resetChanged), [false, false, true, false])
        XCTAssertEqual(chart.points.map(\.remainingPercent), [60, 50, 95, 75])
        let nearest = chart.nearestPoint(to: Date(timeIntervalSince1970: 2.25))
        XCTAssertEqual(nearest?.remainingPercent, 95)
        XCTAssertEqual(nearest?.resetsAt, secondReset)
        XCTAssertEqual(chart.csv(provider: .gemini, period: .weekly).split(separator: "\n").count, 5)
        XCTAssertTrue(chart.csv(provider: .gemini, period: .weekly).contains("gemini,weekly,1970-01-01T00:00:01Z,50,"))
    }
}
