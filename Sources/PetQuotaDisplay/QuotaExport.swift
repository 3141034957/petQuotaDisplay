import Foundation
import QuotaCore

struct QuotaExport: Encodable {
    enum Status: String, Encodable {
        case current, refreshing, stale
    }

    struct Period: Encodable {
        let id: String
        let remainingPercent: Int
        let resetsAt: Date?
    }

    let provider: String
    let codexLimitID: String?
    let status: Status
    let fetchedAt: Date
    let periods: [Period]

    init?(provider: QuotaProvider, state: QuotaDisplayState, model: CodexMeteredQuota? = nil) {
        guard let primary = state.snapshot else { return nil }
        let snapshot = model?.snapshot ?? primary
        self.provider = provider.rawValue
        codexLimitID = model?.id
        fetchedAt = snapshot.fetchedAt
        if state.errorMessage != nil {
            status = .stale
        } else {
            status = state.isRefreshing ? .refreshing : .current
        }
        periods = QuotaPeriod.allCases.compactMap { period in
            snapshot[period].map { Period(id: period.rawValue, remainingPercent: $0.remainingPercent, resetsAt: $0.resetsAt) }
        }
    }

    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
