import Foundation

public struct QuotaReadingHistory {
    public enum Change: Equatable {
        case remainingPercentagePoints(Int)
        case resetTimeChanged
    }

    public private(set) var latest: QuotaSnapshot?
    private var previous: QuotaSnapshot?

    public init() {}

    public mutating func record(_ snapshot: QuotaSnapshot) {
        if let latest {
            guard snapshot.fetchedAt >= latest.fetchedAt else { return }
            if snapshot.fetchedAt > latest.fetchedAt { previous = latest }
        }
        latest = snapshot
    }

    public func change(in period: QuotaPeriod) -> Change? {
        guard let before = previous?[period], let after = latest?[period] else { return nil }
        if let previousReset = before.resetsAt, let latestReset = after.resetsAt, previousReset != latestReset {
            return .resetTimeChanged
        }
        let change = after.remainingPercent - before.remainingPercent
        return change == 0 ? nil : .remainingPercentagePoints(change)
    }
}
