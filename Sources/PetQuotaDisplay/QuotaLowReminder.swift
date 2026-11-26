import Foundation
import QuotaCore

struct QuotaReminderScope: Hashable {
    let context: QuotaHistoryContext
    let modelID: String?
}

struct QuotaLowReminder {
    struct Event: Equatable {
        let period: QuotaPeriod
        let remainingPercent: Int
        let resetsAt: Date?
    }

    private struct Reading {
        let isLow: Bool
        let resetsAt: Date?
        let fetchedAt: Date
    }

    private var previous: [QuotaReminderScope: [QuotaPeriod: Reading]] = [:]

    mutating func events(for scope: QuotaReminderScope, snapshot: QuotaSnapshot,
                         threshold: QuotaWarningThreshold, periods: Set<QuotaPeriod> = Set(QuotaPeriod.allCases),
                         now: Date = Date()) -> [Event] {
        var events: [Event] = []
        for period in QuotaPeriod.allCases where periods.contains(period) {
            guard let window = snapshot[period], window.resetsAt.map({ $0 > now }) ?? true else { continue }
            let last = previous[scope]?[period]
            if let last, snapshot.fetchedAt < last.fetchedAt { continue }
            let low = threshold.includes(remainingPercent: window.remainingPercent)
            let updatedReset = window.resetsAt ?? last?.resetsAt
            let newWindow = last?.resetsAt.map { $0 != updatedReset } ?? false
            if low, last?.isLow != true || newWindow {
                events.append(Event(period: period, remainingPercent: window.remainingPercent, resetsAt: window.resetsAt))
            }
            previous[scope, default: [:]][period] = Reading(isLow: low, resetsAt: updatedReset, fetchedAt: snapshot.fetchedAt)
        }
        return events
    }

    mutating func remove(_ context: QuotaHistoryContext) {
        previous = previous.filter { $0.key.context != context }
    }

    mutating func reset(_ period: QuotaPeriod) {
        for scope in Array(previous.keys) { previous[scope]?.removeValue(forKey: period) }
    }
}
