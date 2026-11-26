import Foundation
import QuotaCore

struct QuotaHistoryRecord: Codable {
    struct Period: Codable {
        let id: String
        let remainingPercent: Int
        let resetsAt: Date?
    }

    let fetchedAt: Date
    let periods: [Period]

    init(_ snapshot: QuotaSnapshot, selecting selection: String? = nil) {
        fetchedAt = snapshot.fetchedAt
        let selected: [QuotaPeriod]
        if selection == QuotaWindowPreference.lowestRemaining {
            let lowest = QuotaWindowPreference.lowestPeriod { snapshot[$0]?.remainingPercent }
            selected = lowest.map { [$0] } ?? []
        } else if let selection {
            selected = QuotaPeriod(rawValue: selection).map { [$0] } ?? []
        } else {
            selected = QuotaPeriod.allCases
        }
        periods = selected.compactMap { period in
            snapshot[period].map { Period(id: period.rawValue, remainingPercent: $0.remainingPercent, resetsAt: $0.resetsAt) }
        }
    }

    var snapshot: QuotaSnapshot? {
        guard Self.isSupportedDate(fetchedAt) else { return nil }
        var windows: [QuotaPeriod: QuotaWindow] = [:]
        for value in periods {
            guard let period = QuotaPeriod(rawValue: value.id), (0...100).contains(value.remainingPercent) else { continue }
            let reset = value.resetsAt.flatMap { Self.isSupportedDate($0) ? $0 : nil }
            windows[period] = QuotaWindow(usedPercent: 100 - value.remainingPercent, resetsAt: reset)
        }
        guard !windows.isEmpty else { return nil }
        return QuotaSnapshot(planType: nil, fiveHour: windows[.fiveHour], weekly: windows[.weekly],
                             monthly: windows[.monthly], fetchedAt: fetchedAt)
    }

    private static func isSupportedDate(_ date: Date) -> Bool {
        (0...253_402_300_799).contains(date.timeIntervalSince1970)
    }
}

struct QuotaHistoryExport: Encodable {
    let schemaVersion = 1
    let provider: String
    let modelID: String?
    let readings: [QuotaHistoryRecord]

    init(provider: QuotaProvider, snapshots: [QuotaSnapshot], modelID: String? = nil,
         selecting period: String? = nil, limit: Int? = nil) {
        self.provider = provider.rawValue
        self.modelID = modelID
        let filtered = snapshots.map { QuotaHistoryRecord($0, selecting: period) }.filter { !$0.periods.isEmpty }
        readings = limit.map { Array(filtered.suffix($0)) } ?? filtered
    }

    func render(as format: QuotaExport.Format) throws -> String {
        let formatter = ISO8601DateFormatter()
        switch format {
        case .json:
            return try QuotaOutput.json(self)
        case .text:
            let title = [QuotaProvider(rawValue: provider)?.title ?? provider, modelID].compactMap { $0 }.joined(separator: " · ")
            guard !readings.isEmpty else { return "\(title) · 暂无保存记录" }
            let lines = readings.map { reading in
                let periods = reading.periods.map { item in
                    let period = QuotaPeriod(rawValue: item.id)?.title ?? item.id
                    return "\(period)剩余 \(item.remainingPercent)%"
                }
                return ([formatter.string(from: reading.fetchedAt)] + periods).joined(separator: " · ")
            }
            return (["\(title) · 额度历史"] + lines).joined(separator: "\n")
        case .csv:
            let rows = readings.flatMap { reading in
                reading.periods.map { item in
                    [provider, item.id, formatter.string(from: reading.fetchedAt), String(item.remainingPercent),
                     item.resetsAt.map(formatter.string(from:)) ?? ""]
                }
            }
            return Self.csv(rows, modelID: modelID)
        }
    }

    static func csv(_ rows: [[String]], modelID: String?) -> String {
        let columns = ["provider", "period", "fetchedAt", "remainingPercent", "resetsAt"]
        if let modelID {
            return QuotaOutput.csv([columns + ["modelID"]] + rows.map { $0 + [modelID] })
        }
        return QuotaOutput.csv([columns] + rows)
    }
}
