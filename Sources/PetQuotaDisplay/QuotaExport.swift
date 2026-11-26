import Foundation
import QuotaCore

struct QuotaExport: Encodable {
    enum Format: String, CaseIterable {
        case json, text, csv
    }

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

    func render(as format: Format) throws -> String {
        switch format {
        case .json: return try json()
        case .text: return text()
        case .csv: return csv()
        }
    }

    private func csv() -> String {
        let fields = ["provider", "codexLimitID", "status", "fetchedAt", "period", "remainingPercent", "resetsAt"]
        let formatter = ISO8601DateFormatter()
        let prefix = [provider, codexLimitID ?? "", status.rawValue, formatter.string(from: fetchedAt)]
        let rows = periods.map { period in
            prefix + [period.id, String(period.remainingPercent), period.resetsAt.map(formatter.string(from:)) ?? ""]
        }
        let special = CharacterSet(charactersIn: ",\"\r\n")
        return ([fields] + rows).map { row in
            row.map { field in
                guard field.rangeOfCharacter(from: special) != nil else { return field }
                return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }

    private func text() -> String {
        let providerTitle = QuotaProvider(rawValue: provider)?.title ?? provider
        let statusTitle: String
        switch status {
        case .current: statusTitle = "当前结果"
        case .refreshing: statusTitle = "正在刷新，显示上次结果"
        case .stale: statusTitle = "上次结果"
        }
        let formatter = ISO8601DateFormatter()
        let source = [providerTitle, codexLimitID, statusTitle].compactMap { $0 }.joined(separator: " · ")
        let rows = periods.map { period in
            let title = QuotaPeriod(rawValue: period.id)?.title ?? period.id
            let reset = period.resetsAt.map(formatter.string(from:)) ?? "未知"
            return "\(title)剩余 \(period.remainingPercent)% · 重置时间 \(reset)"
        }
        return ([source, "采集时间 \(formatter.string(from: fetchedAt))"] + rows).joined(separator: "\n")
    }
}
