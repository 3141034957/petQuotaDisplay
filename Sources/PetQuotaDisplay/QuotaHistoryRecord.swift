import Foundation
import QuotaCore

struct QuotaHistoryRecord: Codable {
    struct Period: Codable {
        let id: String
        let remainingPercent: Int
        let resetsAt: Date?
    }

    struct Portable: Codable {
        let fetchedAt: Date
        let fetchedAtSecondsSince2001: TimeInterval?
        let periods: [Period]

        init(_ reading: QuotaHistoryRecord) {
            fetchedAt = reading.fetchedAt
            let seconds = fetchedAt.timeIntervalSinceReferenceDate
            fetchedAtSecondsSince2001 = seconds.rounded(.down) == seconds ? nil : seconds
            periods = reading.periods
        }

        var snapshot: QuotaSnapshot? {
            let date: Date
            if let seconds = fetchedAtSecondsSince2001 {
                guard seconds.isFinite, abs(seconds - fetchedAt.timeIntervalSinceReferenceDate) < 1 else { return nil }
                date = Date(timeIntervalSinceReferenceDate: seconds)
            } else {
                date = fetchedAt
            }
            return QuotaHistoryRecord(fetchedAt: date, periods: periods).snapshot
        }
    }

    let fetchedAt: Date
    let periods: [Period]

    private init(fetchedAt: Date, periods: [Period]) {
        self.fetchedAt = fetchedAt
        self.periods = periods
    }

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
    static let csvColumns = ["provider", "period", "fetchedAt", "remainingPercent", "resetsAt"]
    let schemaVersion = 1
    let provider: String
    let modelID: String?
    let readings: [QuotaHistoryRecord]

    private enum CodingKeys: String, CodingKey { case schemaVersion, provider, modelID, readings }

    init(provider: QuotaProvider, snapshots: [QuotaSnapshot], modelID: String? = nil,
         selecting period: String? = nil, limit: Int? = nil) {
        self.provider = provider.rawValue
        self.modelID = modelID
        let filtered = snapshots.map { QuotaHistoryRecord($0, selecting: period) }.filter { !$0.periods.isEmpty }
        readings = limit.map { Array(filtered.suffix($0)) } ?? filtered
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(schemaVersion, forKey: .schemaVersion)
        try fields.encode(provider, forKey: .provider)
        try fields.encodeIfPresent(modelID, forKey: .modelID)
        try fields.encode(readings.map(QuotaHistoryRecord.Portable.init), forKey: .readings)
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
            return Self.csv(csvRows(), modelID: modelID)
        }
    }

    func csvRows() -> [[String]] {
        let formatter = ISO8601DateFormatter()
        return readings.flatMap { reading in
            reading.periods.map { item in
                [provider, item.id, formatter.string(from: reading.fetchedAt), String(item.remainingPercent),
                 item.resetsAt.map(formatter.string(from:)) ?? ""]
            }
        }
    }

    private static func csv(_ rows: [[String]], modelID: String?) -> String {
        if let modelID {
            return QuotaOutput.csv([csvColumns + ["modelID"]] + rows.map { $0 + [modelID] })
        }
        return QuotaOutput.csv([csvColumns] + rows)
    }
}

struct QuotaHistoryBatchExport: Encodable {
    let sources: [QuotaHistoryExport]

    func render(as format: QuotaExport.Format) throws -> String {
        switch format {
        case .json:
            return try QuotaOutput.json(self)
        case .text:
            return try sources.map { try $0.render(as: .text) }.joined(separator: "\n\n")
        case .csv:
            let rows = sources.flatMap { source in source.csvRows().map { $0 + [source.modelID ?? ""] } }
            return QuotaOutput.csv([QuotaHistoryExport.csvColumns + ["modelID"]] + rows)
        }
    }
}
