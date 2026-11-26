import QuotaCore
import XCTest
@testable import PetQuotaDisplay

final class QuotaLowReminderTests: XCTestCase {
    func testSystemNoticeCombinesAffectedPeriods() {
        let notice = QuotaNotificationService.content(provider: .kimiCode, events: [
            .init(period: .fiveHour, remainingPercent: 12, resetsAt: nil),
            .init(period: .weekly, remainingPercent: 8, resetsAt: nil),
        ])
        XCTAssertEqual(notice.title, "Kimi Code 额度提醒")
        XCTAssertEqual(notice.body, "5 小时剩余 12%，本周剩余 8%")
        XCTAssertNil(notice.sound)
    }

    func testReminderOnlyFiresForANewLowWindowOrAfterRecovery() {
        var tracker = QuotaLowReminder()
        let scope = QuotaReminderScope(context: .init(provider: .gemini, account: nil), modelID: nil)
        func events(at sequence: Int, remaining: Int, reset: Int) -> [QuotaLowReminder.Event] {
            let now = Date(timeIntervalSince1970: Double(sequence))
            let window = QuotaWindow(usedPercent: 100 - remaining, resetsAt: Date(timeIntervalSince1970: Double(reset)))
            let snapshot = QuotaSnapshot(planType: nil, fiveHour: nil, weekly: window, fetchedAt: now)
            return tracker.events(for: scope, snapshot: snapshot, threshold: .twentyPercent, now: now)
        }
        XCTAssertTrue(events(at: 1, remaining: 21, reset: 10).isEmpty)
        XCTAssertEqual(events(at: 2, remaining: 20, reset: 10).map(\.period), [.weekly])
        XCTAssertTrue(events(at: 3, remaining: 10, reset: 10).isEmpty)
        XCTAssertTrue(events(at: 4, remaining: 50, reset: 10).isEmpty)
        XCTAssertEqual(events(at: 5, remaining: 10, reset: 10).count, 1)
        XCTAssertTrue(events(at: 10, remaining: 10, reset: 10).isEmpty)
        XCTAssertEqual(events(at: 11, remaining: 10, reset: 20).count, 1)
    }
}
