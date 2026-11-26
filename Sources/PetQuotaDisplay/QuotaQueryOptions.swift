import Foundation
import QuotaCore

struct QuotaQueryOptions {
    private enum Option: String, CaseIterable {
        case provider = "--provider"
        case period = "--period"
        case timeout = "--timeout"
        case format = "--format"
        case failBelow = "--fail-below"
        case requireFresh = "--require-fresh"
        case model = "--model"

        var requiresValue: Bool { self != .requireFresh }
    }

    private(set) var provider: QuotaProvider?
    private(set) var period: String?
    private(set) var timeout: TimeInterval = 65
    private(set) var format: QuotaExport.Format = .json
    private(set) var failBelow: Int?
    private(set) var requireFresh = false
    private(set) var modelID: String?

    init(arguments: [String]) throws {
        var arguments = arguments[...]
        var seen = Set<Option>()
        while let argument = arguments.popFirst() {
            guard let option = Option(rawValue: argument) else { throw Failure.unknownOption }
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
            }
        }
    }

    private enum Failure: LocalizedError {
        case unknownOption, invalidValue(Option)

        var errorDescription: String? {
            switch self {
            case .unknownOption: return "--query 接受 \(Option.allCases.map(\.rawValue).joined(separator: "、")) 选项。"
            case .invalidValue(let option): return "请为 \(option.rawValue) 指定一个有效的值。"
            }
        }
    }
}
