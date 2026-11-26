import Foundation
import QuotaCore

enum QuotaQuery {
    static func snapshot(from provider: QuotaProvider, timeout: TimeInterval, modelID: String? = nil,
                         accountSelector: String? = nil) throws -> QuotaExport {
        guard modelID == nil || provider == .codex else { throw Failure.modelOnlyForCodex }
        guard accountSelector == nil || provider == .codex else { throw Failure.accountOnlyForCodex }
        defer { QuotaChildProcess.waitForTerminations() }
        let state: QuotaDisplayState
        switch provider {
        case .claudeCode:
            state = try ClaudeQuotaCache.read()
        case .codex:
            let report = try codexReport(timeout: timeout, accountSelector: accountSelector)
            return try codexExport(from: report, modelID: modelID)
        case .gemini:
            state = try run(GeminiQuotaClient(), timeout: timeout)
        case .openCodeGo:
            let client = OpenCodeGoQuotaClient(readKey: { try OpenCodeGoKeychain.read(allowInteraction: false) })
            state = try run(client, timeout: timeout)
        case .kimiCode:
            state = try run(KimiQuotaClient(), timeout: timeout)
        }

        guard let export = QuotaExport(provider: provider, state: state) else { throw Failure.noResult }
        return export
    }

    static func codexReport(timeout: TimeInterval, accountSelector: String?) throws -> CodexQuotaReport {
        let accounts = CodexAccountProfile.loadAccounts(persistNormalization: false)
        let requested = try accountSelector.map { try CodexAccountProfile.account(matching: $0, in: accounts) }
        guard let account = requested ?? CodexAccountProfile.selectedAccount(in: accounts),
              CodexAccountProfile.hasStoredCredentials(for: account) else { throw Failure.codexAccountRequired }
        let client = CodexQuotaClient(codexHome: try CodexAccountProfile.homeURL(for: account, create: false))
        defer {
            client.stop()
            QuotaChildProcess.waitForTerminations()
        }
        return try waitForResult(timeout: timeout) { complete in
            client.onAccount = { account in
                if account == nil { complete(.failure(Failure.codexAccountRequired)) }
            }
            client.onError = { complete(.failure($0)) }
            client.onReport = { complete(.success($0)) }
            client.start()
        }
    }

    static func codexExport(from report: CodexQuotaReport, modelID: String?) throws -> QuotaExport {
        let model: CodexMeteredQuota?
        if let modelID, modelID != "codex", modelID != report.primaryID {
            guard let selected = report.additional.first(where: { $0.id == modelID }) else { throw Failure.unknownModel }
            model = selected
        } else {
            model = nil
        }
        guard let export = QuotaExport(provider: .codex, state: .loaded(report.primary), model: model) else {
            throw Failure.noResult
        }
        return export
    }

    private static func run(_ client: PollingQuotaClient, timeout: TimeInterval) throws -> QuotaDisplayState {
        defer { client.stop() }
        let snapshot: QuotaSnapshot = try waitForResult(timeout: timeout) { complete in
            client.onResult = complete
            client.refresh()
        }
        return .loaded(snapshot)
    }

    private static func waitForResult<Value>(
        timeout: TimeInterval,
        start: (@escaping (Result<Value, Error>) -> Void) -> Void
    ) throws -> Value {
        var result: Result<Value, Error>?
        func complete(_ response: Result<Value, Error>) {
            if result == nil { result = response }
        }

        let deadline = Date().addingTimeInterval(timeout)
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { _ in }
        RunLoop.main.add(timer, forMode: .default)
        defer { timer.invalidate() }
        start(complete)
        while result == nil, deadline > Date() {
            _ = RunLoop.main.run(mode: .default, before: deadline)
        }
        guard let result else { throw Failure.timedOut }
        return try result.get()
    }

    private enum Failure: LocalizedError {
        case codexAccountRequired, timedOut, noResult, modelOnlyForCodex, accountOnlyForCodex, unknownModel

        var errorDescription: String? {
            switch self {
            case .codexAccountRequired: return "请先在悬浮球添加并登录 Codex 额度账号"
            case .timedOut: return "读取额度超时"
            case .noResult: return "没有可导出的额度结果"
            case .modelOnlyForCodex: return "--model 仅适用于 Codex 额度查询"
            case .accountOnlyForCodex: return "--account 仅适用于 Codex 额度查询"
            case .unknownModel: return "Codex 未返回指定模型的独立额度"
            }
        }
    }
}
