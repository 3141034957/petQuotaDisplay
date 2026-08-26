import Foundation

public struct QuotaWindow: Equatable {
    public let usedPercent: Int
    public let resetsAt: Date?

    public init(usedPercent: Int, resetsAt: Date?) {
        self.usedPercent = min(100, max(0, usedPercent))
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Int { 100 - usedPercent }
}

public typealias WeeklyQuota = QuotaWindow

public struct QuotaSnapshot: Equatable {
    public let planType: String?
    public let fiveHour: QuotaWindow
    public let weekly: QuotaWindow
    public let fetchedAt: Date

    public init(
        planType: String?,
        fiveHour: QuotaWindow,
        weekly: QuotaWindow,
        fetchedAt: Date = Date()
    ) {
        self.planType = planType
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.fetchedAt = fetchedAt
    }
}

public struct CodexAccountSummary: Equatable {
    public let email: String?
    public let planType: String?

    public init(email: String?, planType: String?) {
        self.email = email
        self.planType = planType
    }
}

public enum CodexAccountParser {
    /// Parses the `result` object returned by `account/read`.
    public static func parse(result: [String: Any]) -> CodexAccountSummary? {
        guard let account = result["account"] as? [String: Any] else { return nil }
        guard account["type"] as? String == "chatgpt" else {
            return CodexAccountSummary(email: nil, planType: account["type"] as? String)
        }
        return CodexAccountSummary(
            email: account["email"] as? String,
            planType: account["planType"] as? String
        )
    }
}

public enum QuotaParseError: LocalizedError, Equatable {
    case missingRateLimits
    case missingFiveHourWindow
    case missingWeeklyWindow

    public var errorDescription: String? {
        switch self {
        case .missingRateLimits:
            return "Codex 没有返回额度信息"
        case .missingFiveHourWindow:
            return "Codex 没有返回 5 小时额度"
        case .missingWeeklyWindow:
            return "Codex 没有返回周额度"
        }
    }
}

public enum QuotaParser {
    public static let fiveHourDurationMinutes = 5 * 60
    public static let weeklyDurationMinutes = 7 * 24 * 60

    /// Parses the `result` object returned by `account/rateLimits/read`.
    public static func parse(result: [String: Any], now: Date = Date()) throws -> QuotaSnapshot {
        guard let limits = result["rateLimits"] as? [String: Any] else {
            throw QuotaParseError.missingRateLimits
        }

        let candidates = ["primary", "secondary"].compactMap { limits[$0] as? [String: Any] }
        guard let fiveHour = window(durationMinutes: fiveHourDurationMinutes, in: candidates) else {
            throw QuotaParseError.missingFiveHourWindow
        }
        guard let weekly = window(durationMinutes: weeklyDurationMinutes, in: candidates) else {
            throw QuotaParseError.missingWeeklyWindow
        }

        return QuotaSnapshot(
            planType: limits["planType"] as? String,
            fiveHour: fiveHour,
            weekly: weekly,
            fetchedAt: now
        )
    }

    private static func window(
        durationMinutes: Int,
        in candidates: [[String: Any]]
    ) -> QuotaWindow? {
        guard let candidate = candidates.first(where: {
            integer($0["windowDurationMins"]) == durationMinutes
        }), let usedPercent = integer(candidate["usedPercent"]) else {
            return nil
        }

        let resetSeconds = integer(candidate["resetsAt"])
        return QuotaWindow(
            usedPercent: usedPercent,
            resetsAt: resetSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}
