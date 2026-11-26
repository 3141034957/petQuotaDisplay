import Foundation

enum QuotaHistoryCommand {
    static func render(options: QuotaQueryOptions) throws -> String {
        let archive = QuotaHistoryArchive.local
        if let providers = options.batchProviders {
            let account = providers.contains(.codex) ? try codexAccount(matching: options.account) : nil
            let contexts = providers.map { QuotaHistoryContext(provider: $0, account: $0 == .codex ? account : nil) }
            let report = try archive.exportBatch(for: contexts, selecting: options.period, since: options.since,
                                                 until: options.until, limit: options.limit)
            return try report.render(as: options.format)
        }
        let provider = options.provider ?? (options.listModels ? .codex : QuotaPreferences.selectedProvider())
        let account: CodexAccountSlot?
        if provider == .codex {
            guard let selected = try codexAccount(matching: options.account) else {
                throw Failure.accountRequired
            }
            account = selected
        } else {
            guard options.account == nil else { throw Failure.accountOnlyForCodex }
            guard options.modelID == nil else { throw Failure.modelOnlyForCodex }
            account = nil
        }
        if options.listModels, let account {
            return try archive.modelCatalog(for: account).render(as: options.format)
        }
        let modelID = options.modelID == "codex" ? nil : options.modelID
        let context = QuotaHistoryContext(provider: provider, account: account, modelID: modelID)
        let export = try archive.export(for: context, selecting: options.period, since: options.since,
                                        until: options.until, limit: options.limit)
        return try export.render(as: options.format)
    }

    private static func codexAccount(matching selector: String?) throws -> CodexAccountSlot? {
        let accounts = CodexAccountProfile.loadAccounts(persistNormalization: false)
        if let selector { return try CodexAccountProfile.account(matching: selector, in: accounts) }
        return CodexAccountProfile.selectedAccount(in: accounts)
    }

    private enum Failure: LocalizedError {
        case accountRequired, accountOnlyForCodex, modelOnlyForCodex

        var errorDescription: String? {
            switch self {
            case .accountRequired: return "尚未添加 Codex 额度账号"
            case .accountOnlyForCodex: return "--account 仅适用于 Codex 额度历史"
            case .modelOnlyForCodex: return "--model 仅适用于 Codex 额度历史"
            }
        }
    }
}
