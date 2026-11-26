import Foundation
import XCTest
@testable import QuotaCore

final class QuotaReadingHistoryTests: XCTestCase {
    func testHistoryIgnoresOlderReadingsAndReplacesAnIdenticalCaptureTime() {
        var history = QuotaReadingHistory()
        history.record(snapshot(at: 10, used: 10, reset: 100))
        history.record(snapshot(at: 20, used: 30, reset: 100))
        history.record(snapshot(at: 15, used: 50, reset: 100))
        XCTAssertEqual(history.change(in: .weekly), .remainingPercentagePoints(-20))
        XCTAssertEqual(history.latest?.weekly?.remainingPercent, 70)

        history.record(snapshot(at: 20, used: 25, reset: 100))
        XCTAssertEqual(history.change(in: .weekly), .remainingPercentagePoints(-15))
        XCTAssertNil(history.change(in: .fiveHour))
    }

    func testHistoryIdentifiesAChangedResetTime() {
        var history = QuotaReadingHistory()
        history.record(snapshot(at: 10, used: 80, reset: 30))
        history.record(snapshot(at: 35, used: 0, reset: 60))
        XCTAssertEqual(history.change(in: .weekly), .resetTimeChanged)
    }

    func testHistoryKeepsOnlyTheLatestBoundedNumberOfReadings() {
        var history = QuotaReadingHistory()
        let maximum = QuotaReadingHistory.maximumReadings
        for time in 0...maximum {
            history.record(snapshot(at: TimeInterval(time), used: time % 100, reset: 1000))
        }
        XCTAssertEqual(history.readings.count, maximum)
        XCTAssertEqual(history.readings.first?.fetchedAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(history.latest?.fetchedAt, Date(timeIntervalSince1970: TimeInterval(maximum)))
    }

    private func snapshot(at time: TimeInterval, used: Int, reset: TimeInterval) -> QuotaSnapshot {
        QuotaSnapshot(
            planType: nil, fiveHour: nil,
            weekly: QuotaWindow(usedPercent: used, resetsAt: Date(timeIntervalSince1970: reset)),
            fetchedAt: Date(timeIntervalSince1970: time)
        )
    }
}
