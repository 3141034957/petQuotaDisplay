import Foundation
import QuotaCore

struct QuotaHistoryContext: Hashable {
    let provider: QuotaProvider
    let account: CodexAccountSlot?
    let modelID: String?

    init(provider: QuotaProvider, account: CodexAccountSlot?, modelID: String? = nil) {
        self.provider = provider
        self.account = account
        self.modelID = modelID
    }

    var primary: Self { Self(provider: provider, account: account) }
}

struct QuotaHistorySeries {
    enum TimeRange: String, CaseIterable {
        case quarterHour = "15m"
        case hour = "1h"
        case sixHours = "6h"
        case day = "24h"
        case week = "7d"
        case all

        var title: String {
            switch self {
            case .quarterHour: return "最近 15 分钟"
            case .hour: return "最近 1 小时"
            case .sixHours: return "最近 6 小时"
            case .day: return "最近 24 小时"
            case .week: return "最近 7 天"
            case .all: return "全部记录"
            }
        }

        var duration: TimeInterval? {
            switch self {
            case .quarterHour: return 15 * 60
            case .hour: return 60 * 60
            case .sixHours: return 6 * 3_600
            case .day: return 24 * 3_600
            case .week: return 7 * 24 * 3_600
            case .all: return nil
            }
        }

        func cutoff(relativeTo latest: Date?) -> Date? {
            duration.flatMap { interval in latest?.addingTimeInterval(-interval) }
        }
    }

    struct Point: Identifiable {
        let time: Date
        let remainingPercent: Int
        let resetsAt: Date?
        let resetChanged: Bool
        let segment: Int

        var id: Date { time }
    }

    func csv(provider: QuotaProvider, period: QuotaPeriod, modelID: String? = nil) -> String {
        let formatter = ISO8601DateFormatter()
        let rows = points.map { point in
            [provider.rawValue, period.rawValue, formatter.string(from: point.time),
             String(point.remainingPercent), point.resetsAt.map(formatter.string(from:)) ?? ""]
        }
        return QuotaHistoryExport.csv(rows, modelID: modelID)
    }

    let points: [Point]

    init(readings: [QuotaSnapshot], period: QuotaPeriod, range: TimeRange = .all) {
        var points: [Point] = []
        var segment = 0
        var lastKnownReset: Date?
        var containsGap = false
        let cutoff = range.cutoff(relativeTo: readings.last?.fetchedAt)
        for reading in readings where cutoff.map({ reading.fetchedAt >= $0 }) ?? true {
            guard let window = reading[period] else {
                containsGap = !points.isEmpty
                continue
            }
            let resetChanged = window.resetsAt.flatMap { reset in lastKnownReset.map { reset != $0 } } ?? false
            if containsGap || resetChanged { segment += 1 }
            points.append(Point(time: reading.fetchedAt, remainingPercent: window.remainingPercent,
                                resetsAt: window.resetsAt, resetChanged: resetChanged, segment: segment))
            if containsGap { lastKnownReset = nil }
            if let reset = window.resetsAt { lastKnownReset = reset }
            containsGap = false
        }
        self.points = points
    }

    func nearestPoint(to time: Date) -> Point? {
        points.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
    }

    func point(adjacentTo time: Date, offset: Int) -> Point? {
        guard let index = points.firstIndex(where: { $0.time == time }),
              points.indices.contains(index + offset) else { return nil }
        return points[index + offset]
    }
}
