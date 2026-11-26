import Foundation

public struct QuotaReadingHistory {
    public enum Change: Equatable {
        case remainingPercentagePoints(Int)
        case resetTimeChanged
    }

    public static let maximumReadings = 120
    public private(set) var readings: [QuotaSnapshot] = []
    public var latest: QuotaSnapshot? { readings.last }

    public init() {}

    public mutating func record(_ snapshot: QuotaSnapshot) {
        if let latest {
            guard snapshot.fetchedAt >= latest.fetchedAt else { return }
            if snapshot.fetchedAt == latest.fetchedAt {
                readings[readings.count - 1] = snapshot
                return
            }
        }
        readings.append(snapshot)
        if readings.count > Self.maximumReadings {
            readings.removeFirst(readings.count - Self.maximumReadings)
        }
    }

    public func change(in period: QuotaPeriod) -> Change? {
        guard let before = readings.dropLast().last?[period], let after = latest?[period] else { return nil }
        if let previousReset = before.resetsAt, let latestReset = after.resetsAt, previousReset != latestReset {
            return .resetTimeChanged
        }
        let change = after.remainingPercent - before.remainingPercent
        return change == 0 ? nil : .remainingPercentagePoints(change)
    }
}
