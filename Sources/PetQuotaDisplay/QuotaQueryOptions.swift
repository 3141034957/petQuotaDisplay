import Foundation
import QuotaCore

struct QuotaQueryOptions {
    private(set) var provider: QuotaProvider?
    private(set) var period: String?
    private(set) var timeout: TimeInterval = 65

    init(arguments: [String]) throws {
        var arguments = arguments[...]
        var seen = Set<String>()
        while let option = arguments.popFirst() {
            guard ["--provider", "--period", "--timeout"].contains(option) else {
                throw Failure.unknownOption
            }
            guard seen.insert(option).inserted, let value = arguments.popFirst() else {
                throw Failure.invalidValue(option)
            }
            switch option {
            case "--provider":
                guard let provider = QuotaProvider(rawValue: value) else { throw Failure.invalidValue(option) }
                self.provider = provider
            case "--period":
                guard QuotaPeriod(rawValue: value) != nil || value == QuotaWindowPreference.lowestRemaining else {
                    throw Failure.invalidValue(option)
                }
                period = value
            case "--timeout":
                guard let seconds = Int(value), (1...3600).contains(seconds) else { throw Failure.invalidValue(option) }
                timeout = TimeInterval(seconds)
            default:
                throw Failure.unknownOption
            }
        }
    }

    private enum Failure: LocalizedError {
        case unknownOption, invalidValue(String)

        var errorDescription: String? {
            switch self {
            case .unknownOption: return "--query 接受 --provider、--period 和 --timeout 选项。"
            case .invalidValue(let option): return "请为 \(option) 指定一个有效的值。"
            }
        }
    }
}
