import CoreFoundation
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
    /// `nil` on plans that no longer publish a 5-hour window, such as ChatGPT Pro.
    public let fiveHour: QuotaWindow?
    public let weekly: QuotaWindow?
    public let monthly: QuotaWindow?
    public let fetchedAt: Date

    public init(
        planType: String?,
        fiveHour: QuotaWindow?,
        weekly: QuotaWindow?,
        monthly: QuotaWindow? = nil,
        fetchedAt: Date = Date()
    ) {
        self.planType = planType
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.monthly = monthly
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
    case missingQuotaWindow

    public var errorDescription: String? {
        switch self {
        case .missingRateLimits:
            return "Codex 没有返回额度信息"
        case .missingQuotaWindow:
            return "Codex 没有返回可用的额度窗口"
        }
    }
}

public struct CodexMeteredQuota: Equatable {
    public let id: String
    public let name: String
    public let snapshot: QuotaSnapshot

    public init(id: String, name: String, snapshot: QuotaSnapshot) {
        self.id = id
        self.name = name
        self.snapshot = snapshot
    }
}

public struct CodexQuotaReport: Equatable {
    public let primary: QuotaSnapshot
    public let additional: [CodexMeteredQuota]
}

public enum QuotaParser {
    public static let fiveHourDurationMinutes = 5 * 60
    public static let weeklyDurationMinutes = 7 * 24 * 60

    /// Parses the `result` object returned by `account/rateLimits/read`.
    public static func parse(result: [String: Any], now: Date = Date()) throws -> QuotaSnapshot {
        try primaryQuota(result, now: now).snapshot
    }

    public static func parseReport(result: [String: Any], now: Date = Date()) throws -> CodexQuotaReport {
        let primary = try primaryQuota(result, now: now)
        let metered = result["rateLimitsByLimitId"] as? [String: Any] ?? [:]
        let additional = metered.keys.sorted().compactMap { id -> CodexMeteredQuota? in
            guard !id.isEmpty, id != "codex", id != primary.id,
                  let bucket = metered[id] as? [String: Any],
                  let snapshot = parseWindows(bucket, now: now) else { return nil }
            let name = (bucket["limitName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return CodexMeteredQuota(id: id, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? id, snapshot: snapshot)
        }
        return CodexQuotaReport(primary: primary.snapshot, additional: additional)
    }

    private static func primaryQuota(_ result: [String: Any], now: Date) throws -> (snapshot: QuotaSnapshot, id: String?) {
        let legacy = result["rateLimits"] as? [String: Any]
        let metered = result["rateLimitsByLimitId"] as? [String: Any]
        let namedCodex = metered?["codex"] as? [String: Any]
        guard legacy != nil || namedCodex != nil else { throw QuotaParseError.missingRateLimits }
        if let legacy, let snapshot = parseWindows(legacy, now: now) {
            return (snapshot, legacy["limitId"] as? String)
        }
        if let namedCodex, let snapshot = parseWindows(namedCodex, now: now) {
            return (snapshot, "codex")
        }
        throw QuotaParseError.missingQuotaWindow
    }

    private static func parseWindows(_ limits: [String: Any], now: Date) -> QuotaSnapshot? {
        let candidates = ["primary", "secondary"].compactMap { limits[$0] as? [String: Any] }
        let fiveHour = window(durationMinutes: fiveHourDurationMinutes, in: candidates)
        let weekly = window(durationMinutes: weeklyDurationMinutes, in: candidates)
        guard fiveHour != nil || weekly != nil else { return nil }

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
        for candidate in candidates where integer(candidate["windowDurationMins"]) == durationMinutes {
            guard let usedPercent = integer(candidate["usedPercent"]) else { continue }
            let resetSeconds = integer(candidate["resetsAt"])
            return QuotaWindow(
                usedPercent: usedPercent,
                resetsAt: resetSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number as? Int
    }
}
