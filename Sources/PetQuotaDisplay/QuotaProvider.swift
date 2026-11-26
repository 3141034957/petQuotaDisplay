import QuotaCore

enum QuotaProvider: String, CaseIterable {
    case codex, gemini, claudeCode, openCodeGo, kimiCode

    var title: String {
        switch self {
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .claudeCode: return "Claude Code"
        case .openCodeGo: return "OpenCode Go"
        case .kimiCode: return "Kimi Code"
        }
    }

    var supportsMonthlyQuota: Bool { self == .openCodeGo || self == .kimiCode }
}

extension QuotaPeriod {
    var title: String {
        switch self {
        case .fiveHour: return "5 小时"
        case .weekly: return "本周"
        case .monthly: return "本月"
        }
    }
}
