import Foundation

struct QuotaDisplayOptions {
    enum Mode: String {
        case followCodex = "--follow-codex"
        case forceOrb = "--always-show"
    }

    private(set) var mode: Mode?
    private(set) var provider: QuotaProvider?

    init(arguments: [String]) throws {
        var arguments = arguments[...]
        while let argument = arguments.popFirst() {
            if let requestedMode = Mode(rawValue: argument) {
                guard mode == nil else { throw Failure.multipleModes }
                mode = requestedMode
            } else if argument == "--provider" {
                guard provider == nil, let name = arguments.popFirst(),
                      let requestedProvider = QuotaProvider(rawValue: name) else { throw Failure.invalidProvider }
                provider = requestedProvider
            } else {
                throw Failure.unknownArgument
            }
        }
    }

    private enum Failure: LocalizedError {
        case multipleModes, invalidProvider, unknownArgument

        var errorDescription: String? {
            switch self {
            case .multipleModes: return "请只选择一种启动模式。"
            case .invalidProvider: return "请为 --provider 指定一个有效的额度来源。"
            case .unknownArgument: return "无法识别启动参数。"
            }
        }
    }
}
