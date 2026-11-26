import QuotaCore
import UserNotifications
import XCTest
@testable import PetQuotaDisplay

final class QuotaLowReminderTests: XCTestCase {
    func testNotificationHistoryRouteKeepsTheCodexAccountScoped() throws {
        let account = try XCTUnwrap(CodexAccountSlot(rawValue: UUID().uuidString))
        let context = QuotaHistoryContext(provider: .codex, account: account)
        let info = QuotaNotificationService.userInfo(for: context)
        XCTAssertEqual(QuotaNotificationService.historyContext(from: info), context)
        let model = QuotaHistoryContext(provider: .codex, account: account, modelID: "extra")
        XCTAssertEqual(QuotaNotificationService.historyContext(from: QuotaNotificationService.userInfo(for: model)), model)
        XCTAssertNil(QuotaNotificationService.historyContext(from: ["provider": "codex"]))
        XCTAssertNil(QuotaNotificationService.historyContext(from: ["provider": "gemini", "account": account.rawValue]))
        XCTAssertNil(QuotaNotificationService.historyContext(from: ["provider": "gemini", "modelID": "extra"]))
    }

    func testNotificationAuthorizationErrorIsDistinguishedFromOtherErrors() {
        let code = UNError.Code.notificationsNotAllowed.rawValue
        XCTAssertTrue(QuotaNotificationService.isAuthorizationError(NSError(domain: UNErrorDomain, code: code)))
        XCTAssertFalse(QuotaNotificationService.isAuthorizationError(NSError(domain: NSCocoaErrorDomain, code: code)))
    }

    func testReminderFiltersPeriodsBeforeRecordingEpisodes() {
        var tracker = QuotaLowReminder()
        let scope = QuotaHistoryContext(provider: .gemini, account: nil)
        let window = QuotaWindow(usedPercent: 95, resetsAt: nil)
        let snapshot = QuotaSnapshot(planType: nil, fiveHour: window, weekly: window)
        XCTAssertEqual(tracker.events(for: scope, snapshot: snapshot, threshold: .twentyPercent,
                                      periods: [.weekly]).map(\.period), [.weekly])
        XCTAssertEqual(tracker.events(for: scope, snapshot: snapshot, threshold: .twentyPercent).map(\.period), [.fiveHour])
    }

    func testSystemNoticeCombinesAffectedPeriods() {
        let notice = QuotaNotificationService.content(provider: .kimiCode, events: [
            .init(period: .fiveHour, remainingPercent: 12, resetsAt: nil),
            .init(period: .weekly, remainingPercent: 8, resetsAt: nil),
        ])
        XCTAssertEqual(notice.title, "Kimi Code 额度提醒")
        XCTAssertEqual(notice.body, "5 小时剩余 12%，本周剩余 8%")
        XCTAssertNil(notice.sound)
        let model = QuotaNotificationService.content(provider: .codex, modelID: "extra", events: [])
        XCTAssertEqual(model.title, "Codex · extra 额度提醒")
    }

    func testReminderOnlyFiresForANewLowWindowOrAfterRecovery() {
        var tracker = QuotaLowReminder()
        let scope = QuotaHistoryContext(provider: .gemini, account: nil)
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
