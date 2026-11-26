import Foundation
import QuotaCore

struct QuotaQueryOptions {
    enum Purpose {
        case live, savedHistory

        var command: String { self == .live ? "--query" : "--history" }
    }

    private enum Option: String, CaseIterable {
        case provider = "--provider"
        case providers = "--providers"
        case all = "--all"
        case period = "--period"
        case timeout = "--timeout"
        case format = "--format"
        case failBelow = "--fail-below"
        case requireFresh = "--require-fresh"
        case model = "--model"
        case account = "--account"
        case listModels = "--list-models"
        case includeModels = "--include-models"
        case summary = "--summary"
        case since = "--since"
        case until = "--until"
        case limit = "--limit"

        var requiresValue: Bool {
            switch self {
            case .requireFresh, .listModels, .includeModels, .all, .summary: return false
            default: return true
            }
        }
    }

    private(set) var provider: QuotaProvider?
    private(set) var batchProviders: [QuotaProvider]?
    private(set) var period: String?
    private(set) var timeout: TimeInterval = 65
    private(set) var format: QuotaExport.Format = .json
    private(set) var failBelow: Int?
    private(set) var requireFresh = false
    private(set) var modelID: String?
    private(set) var account: String?
    private(set) var listModels = false
    private(set) var includesModels = false
    private(set) var summariesOnly = false
    private(set) var since: Date?
    private(set) var until: Date?
    private(set) var limit: Int?

    init(arguments: [String], purpose: Purpose = .live) throws {
        var arguments = arguments[...]
        var seen = Set<Option>()
        let historyOptions: Set<Option> = [
            .provider, .providers, .all, .account, .model, .listModels, .includeModels, .summary,
            .period, .since, .until, .format, .limit,
        ]
        while let argument = arguments.popFirst() {
            guard let option = Option(rawValue: argument) else { throw Failure.unknownOption(purpose) }
            if purpose == .savedHistory, !historyOptions.contains(option) {
                throw Failure.unsupportedHistoryOption(option)
            }
            if purpose == .live, option == .since || option == .until { throw Failure.dateOnlyForHistory }
            if purpose == .live, option == .limit { throw Failure.limitOnlyForHistory }
            if purpose == .live, option == .includeModels { throw Failure.includeModelsRequiresHistoryBatch }
            if purpose == .live, option == .summary { throw Failure.summaryOnlyForHistory }
            guard seen.insert(option).inserted else { throw Failure.duplicateOption(option) }
            if option.requiresValue {
                guard let next = arguments.first, Option(rawValue: next) == nil, next != "--help", next != "-h" else {
                    throw Failure.missingValue(option)
                }
            }
            let value = option.requiresValue ? arguments.popFirst() : nil
            switch option {
            case .all:
                batchProviders = QuotaProvider.allCases
            case .providers:
                guard let value else { throw Failure.invalidValue(option) }
                let names = value.components(separatedBy: ",")
                let providers = names.compactMap { QuotaProvider(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
                guard providers.count == names.count, Set(providers).count == names.count else {
                    throw Failure.invalidValue(option)
                }
                batchProviders = providers
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
            case .includeModels:
                includesModels = true
            case .summary:
                summariesOnly = true
            case .since:
                guard let value, let date = QuotaHTTP.resetDate(value) else { throw Failure.invalidValue(option) }
                since = date
            case .until:
                guard let value, let date = QuotaHTTP.resetDate(value) else { throw Failure.invalidValue(option) }
                until = date
            case .limit:
                guard let value, let count = Int(value), count > 0 else { throw Failure.invalidValue(option) }
                limit = count
            }
        }
        if let batchProviders {
            guard !(seen.contains(.all) && seen.contains(.providers)), provider == nil, modelID == nil, !listModels else {
                throw Failure.incompatibleBatch
            }
            guard account == nil || batchProviders.contains(.codex) else { throw Failure.missingBatchCodex }
        }
        if includesModels, batchProviders?.contains(.codex) != true {
            throw Failure.includeModelsRequiresHistoryBatch
        }
        if listModels {
            var allowed: Set<Option> = [.listModels, .provider, .account, .format]
            if purpose == .live { allowed.insert(.timeout) }
            guard seen.isSubset(of: allowed), provider == nil || provider == .codex else {
                throw Failure.incompatibleModelList(purpose)
            }
        }
        if let since, let until, since > until { throw Failure.invalidDateRange }
    }

    private enum Failure: LocalizedError {
        case unknownOption(Purpose), duplicateOption(Option), missingValue(Option), invalidValue(Option)
        case incompatibleModelList(Purpose), unsupportedHistoryOption(Option)
        case incompatibleBatch, missingBatchCodex
        case includeModelsRequiresHistoryBatch, summaryOnlyForHistory
        case dateOnlyForHistory, invalidDateRange, limitOnlyForHistory

        var errorDescription: String? {
            switch self {
            case .unknownOption(let purpose): return "未知选项。请运行 \(purpose.command) --help 查看支持的参数。"
            case .duplicateOption(let option): return "\(option.rawValue) 只能指定一次。"
            case .missingValue(let option): return "\(option.rawValue) 缺少参数值。"
            case .invalidValue(let option): return "请为 \(option.rawValue) 指定一个有效的值。"
            case .incompatibleBatch: return "请在 --all、--providers 和 --provider 中选择其一。批量查询不支持 --model 或 --list-models。"
            case .missingBatchCodex: return "使用 --account 时，批量查询的来源必须包含 codex。"
            case .includeModelsRequiresHistoryBatch:
                return "--include-models 需要使用包含 Codex 的批量历史查询。"
            case .summaryOnlyForHistory: return "--summary 仅适用于历史查询。"
            case .incompatibleModelList(let purpose):
                let timeout = purpose == .live ? "、超时" : ""
                return "模型列表仅支持 Codex 来源、账号\(timeout)和输出格式选项。"
            case .unsupportedHistoryOption(let option): return "--history 不支持 \(option.rawValue)。"
            case .dateOnlyForHistory: return "--since 和 --until 仅适用于历史查询。"
            case .invalidDateRange: return "历史查询的起始时间不能晚于结束时间。"
            case .limitOnlyForHistory: return "--limit 仅适用于历史查询。"
            }
        }
    }
}
