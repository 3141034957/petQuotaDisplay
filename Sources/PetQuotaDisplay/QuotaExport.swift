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
    private(set) var periods: [Period]

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

    mutating func selectPeriod(_ selection: String) throws {
        let id = selection == QuotaWindowPreference.lowestRemaining
            ? QuotaWindowPreference.lowestPeriod { period in
                periods.first { $0.id == period.rawValue }?.remainingPercent
            }?.rawValue
            : selection
        guard let match = periods.first(where: { $0.id == id }) else { throw UnavailablePeriod() }
        periods = [match]
    }

    private struct UnavailablePeriod: LocalizedError {
        var errorDescription: String? { "此来源未提供所选周期的额度" }
    }

    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
