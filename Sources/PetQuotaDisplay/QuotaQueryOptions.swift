import Foundation
import QuotaCore

struct QuotaQueryOptions {
    enum Purpose {
        case live, savedHistory
    }

    private enum Option: String, CaseIterable {
        case provider = "--provider"
        case period = "--period"
        case timeout = "--timeout"
        case format = "--format"
        case failBelow = "--fail-below"
        case requireFresh = "--require-fresh"
        case model = "--model"
        case account = "--account"
        case listModels = "--list-models"
        case since = "--since"
        case until = "--until"

        var requiresValue: Bool { self != .requireFresh && self != .listModels }
    }

    private(set) var provider: QuotaProvider?
    private(set) var period: String?
    private(set) var timeout: TimeInterval = 65
    private(set) var format: QuotaExport.Format = .json
    private(set) var failBelow: Int?
    private(set) var requireFresh = false
    private(set) var modelID: String?
    private(set) var account: String?
    private(set) var listModels = false
    private(set) var since: Date?
    private(set) var until: Date?

    init(arguments: [String], purpose: Purpose = .live) throws {
        var arguments = arguments[...]
        var seen = Set<Option>()
        while let argument = arguments.popFirst() {
            guard let option = Option(rawValue: argument) else { throw Failure.unknownOption }
            let historyOptions: Set<Option> = [.provider, .account, .period, .since, .until]
            if purpose == .savedHistory, !historyOptions.contains(option) {
                throw Failure.unsupportedHistoryOption
            }
            if purpose == .live, option == .since || option == .until { throw Failure.dateOnlyForHistory }
            guard seen.insert(option).inserted else { throw Failure.invalidValue(option) }
            let value = option.requiresValue ? arguments.popFirst() : nil
            switch option {
            case .provider:
                guard let value, let provider = QuotaProvider(rawValue: value) else { throw Failure.invalidValue(option) }
                self.provider = provider
            case .period:
                guard let value, QuotaPeriod(rawValue: value) != nil || value == QuotaWindowPreference.lowestRemaining else {
                    throw Failure.invalidValue(option)
                }
                period = value
            case .timeout:
                guard let value, let seconds = Int(value), (1...3600).contains(seconds) else { throw Failure.invalidValue(option) }
                timeout = TimeInterval(seconds)
            case .format:
                guard let value, let format = QuotaExport.Format(rawValue: value) else { throw Failure.invalidValue(option) }
                self.format = format
            case .failBelow:
                guard let value, let percent = Int(value), (0...100).contains(percent) else { throw Failure.invalidValue(option) }
                failBelow = percent
            case .requireFresh:
                requireFresh = true
            case .model:
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw Failure.invalidValue(option)
                }
                modelID = value
            case .account:
                guard let value else { throw Failure.invalidValue(option) }
                let name = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard !name.isEmpty else { throw Failure.invalidValue(option) }
                account = name
            case .listModels:
                listModels = true
            case .since:
                guard let value, let date = QuotaHTTP.resetDate(value) else { throw Failure.invalidValue(option) }
                since = date
            case .until:
                guard let value, let date = QuotaHTTP.resetDate(value) else { throw Failure.invalidValue(option) }
                until = date
            }
        }
        if listModels, (provider != nil && provider != .codex || modelID != nil || period != nil || failBelow != nil || requireFresh) {
            throw Failure.incompatibleModelList
        }
        if let since, let until, since > until { throw Failure.invalidDateRange }
    }

    private enum Failure: LocalizedError {
        case unknownOption, invalidValue(Option), incompatibleModelList, unsupportedHistoryOption, dateOnlyForHistory, invalidDateRange

        var errorDescription: String? {
            switch self {
            case .unknownOption: return "--query 接受 \(Option.allCases.map(\.rawValue).joined(separator: "、")) 选项。"
            case .invalidValue(let option): return "请为 \(option.rawValue) 指定一个有效的值。"
            case .incompatibleModelList: return "模型列表仅支持 Codex 来源、账号、超时和输出格式选项。"
            case .unsupportedHistoryOption: return "--history 接受 --provider、--account、--period、--since 和 --until 选项。"
            case .dateOnlyForHistory: return "--since 和 --until 仅适用于历史查询。"
            case .invalidDateRange: return "历史查询的起始时间不能晚于结束时间。"
            }
        }
    }
}
