import QuotaCore

enum QuotaWindowPreference {
    static let legacyKey = "quota.displayedWindow"
    static let lowestRemaining = "lowestRemaining"
    static let presentationOrder: [QuotaPeriod] = [.weekly, .fiveHour, .monthly]

    static func lowestPeriod(remaining: (QuotaPeriod) -> Int?) -> QuotaPeriod? {
        presentationOrder.compactMap { period in
            remaining(period).map { (period: period, remaining: $0) }
        }.min { $0.remaining < $1.remaining }?.period
    }

    static func key(for provider: QuotaProvider, account: CodexAccountSlot? = nil) -> String {
        let providerKey = "\(legacyKey).\(provider.rawValue)"
        guard provider == .codex, let account else { return providerKey }
        return "\(providerKey).\(account.rawValue)"
    }
}
