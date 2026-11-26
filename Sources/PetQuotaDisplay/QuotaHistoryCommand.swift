import Foundation

enum QuotaHistoryCommand {
    static func read(options: QuotaQueryOptions) throws -> QuotaHistoryExport {
        let provider = options.provider ?? QuotaPreferences.selectedProvider()
        let account: CodexAccountSlot?
        if provider == .codex {
            let accounts = CodexAccountProfile.loadAccounts(persistNormalization: false)
            let requested = try options.account.map { try CodexAccountProfile.account(matching: $0, in: accounts) }
            guard let selected = requested ?? CodexAccountProfile.selectedAccount(in: accounts) else {
                throw Failure.accountRequired
            }
            account = selected
        } else {
            guard options.account == nil else { throw Failure.accountOnlyForCodex }
            account = nil
        }
        return try QuotaHistoryArchive.local.export(for: QuotaHistoryContext(provider: provider, account: account),
                                                  selecting: options.period, since: options.since, until: options.until)
    }

    private enum Failure: LocalizedError {
        case accountRequired, accountOnlyForCodex

        var errorDescription: String? {
            switch self {
            case .accountRequired: return "尚未添加 Codex 额度账号"
            case .accountOnlyForCodex: return "--account 仅适用于 Codex 额度历史"
            }
        }
    }
}
