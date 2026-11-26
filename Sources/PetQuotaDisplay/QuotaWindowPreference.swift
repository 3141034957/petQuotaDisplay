enum QuotaWindowPreference {
    static let legacyKey = "quota.displayedWindow"
    static let lowestRemaining = "lowestRemaining"

    static func key(for provider: QuotaProvider, account: CodexAccountSlot? = nil) -> String {
        let providerKey = "\(legacyKey).\(provider.rawValue)"
        guard provider == .codex, let account else { return providerKey }
        return "\(providerKey).\(account.rawValue)"
    }
}
