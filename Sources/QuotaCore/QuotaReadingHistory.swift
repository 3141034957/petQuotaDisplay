import Foundation

public struct QuotaReadingHistory {
    public enum Change: Equatable {
        case remainingPercentagePoints(Int)
        case resetTimeChanged
    }

    public static let maximumReadings = 120
    public private(set) var capacity: Int
    public private(set) var readings: [QuotaSnapshot] = []
    public var latest: QuotaSnapshot? { readings.last }

    public init(capacity: Int = Self.maximumReadings) {
        self.capacity = max(1, capacity)
    }

    public mutating func setCapacity(_ capacity: Int) {
        self.capacity = max(1, capacity)
        trim()
    }

    public mutating func merge(_ additional: [QuotaSnapshot]) {
        readings = Self.merged(readings, with: additional, keepingExisting: true, capacity: capacity)
    }

    public static func merged(_ existing: [QuotaSnapshot], with additional: [QuotaSnapshot],
                              keepingExisting: Bool = false, capacity: Int = maximumReadings) -> [QuotaSnapshot] {
        var readingsByDate: [Date: QuotaSnapshot] = [:]
        for snapshot in keepingExisting ? additional + existing : existing + additional {
            readingsByDate[snapshot.fetchedAt] = snapshot
        }
        return readingsByDate.keys.sorted().suffix(max(1, capacity)).compactMap { readingsByDate[$0] }
    }

    public mutating func record(_ snapshot: QuotaSnapshot) {
        if let latest {
            guard snapshot.fetchedAt >= latest.fetchedAt else { return }
            if snapshot.fetchedAt == latest.fetchedAt {
                readings[readings.count - 1] = snapshot
                return
            }
        }
        readings.append(snapshot)
        trim()
    }

    private mutating func trim() {
        if readings.count > capacity {
            readings.removeFirst(readings.count - capacity)
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
