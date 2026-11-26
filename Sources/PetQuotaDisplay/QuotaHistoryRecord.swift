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

    init(_ snapshot: QuotaSnapshot) {
        fetchedAt = snapshot.fetchedAt
        periods = QuotaPeriod.allCases.compactMap { period in
            snapshot[period].map { Period(id: period.rawValue, remainingPercent: $0.remainingPercent, resetsAt: $0.resetsAt) }
        }
    }
}

struct QuotaHistoryExport: Encodable {
    let schemaVersion = 1
    let provider: String
    let readings: [QuotaHistoryRecord]

    init(provider: QuotaProvider, snapshots: [QuotaSnapshot]) {
        self.provider = provider.rawValue
        readings = snapshots.map(QuotaHistoryRecord.init)
    }
}
