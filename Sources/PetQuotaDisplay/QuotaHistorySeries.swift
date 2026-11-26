import Foundation
import QuotaCore

struct QuotaHistorySeries {
    struct Point: Identifiable {
        let time: Date
        let remainingPercent: Int
        let resetsAt: Date?
        let segment: Int

        var id: Date { time }
    }

    let points: [Point]

    init(readings: [QuotaSnapshot], period: QuotaPeriod) {
        var points: [Point] = []
        var segment = 0
        var lastKnownReset: Date?
        var containsGap = false
        for reading in readings {
            guard let window = reading[period] else {
                containsGap = !points.isEmpty
                continue
            }
            let resetChanged = window.resetsAt.flatMap { reset in lastKnownReset.map { reset != $0 } } ?? false
            if containsGap || resetChanged { segment += 1 }
            points.append(Point(time: reading.fetchedAt, remainingPercent: window.remainingPercent,
                                resetsAt: window.resetsAt, segment: segment))
            if containsGap { lastKnownReset = nil }
            if let reset = window.resetsAt { lastKnownReset = reset }
            containsGap = false
        }
        self.points = points
    }

    func nearestPoint(to time: Date) -> Point? {
        points.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
    }
}
