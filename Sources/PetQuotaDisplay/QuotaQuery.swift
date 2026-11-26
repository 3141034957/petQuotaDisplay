import Foundation
import QuotaCore

enum QuotaQuery {
    static func snapshot(from provider: QuotaProvider, timeout: TimeInterval) throws -> QuotaExport {
        let state: QuotaDisplayState
        switch provider {
        case .claudeCode:
            state = try ClaudeQuotaCache.read()
        case .codex:
            let accounts = CodexAccountProfile.loadAccounts()
            guard let account = CodexAccountProfile.selectedAccount(in: accounts),
                  CodexAccountProfile.hasStoredCredentials(for: account) else { throw Failure.codexAccountRequired }
            let client = CodexQuotaClient(codexHome: try CodexAccountProfile.homeURL(for: account))
            defer { client.stop() }
            state = try waitForResult(timeout: timeout) { complete in
                client.onAccount = { account in
                    if account == nil { complete(.failure(Failure.codexAccountRequired)) }
                }
                client.onError = { complete(.failure($0)) }
                client.onReport = { complete(.success($0.primary)) }
                client.start()
            }
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

    private static func run(_ client: PollingQuotaClient, timeout: TimeInterval) throws -> QuotaDisplayState {
        defer { client.stop() }
        return try waitForResult(timeout: timeout) { complete in
            client.onResult = complete
            client.refresh()
        }
    }

    private static func waitForResult(
        timeout: TimeInterval,
        start: (@escaping (Result<QuotaSnapshot, Error>) -> Void) -> Void
    ) throws -> QuotaDisplayState {
        var result: Result<QuotaSnapshot, Error>?
        func complete(_ response: Result<QuotaSnapshot, Error>) {
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
        return .loaded(try result.get())
    }

    private enum Failure: LocalizedError {
        case codexAccountRequired, timedOut, noResult

        var errorDescription: String? {
            switch self {
            case .codexAccountRequired: return "请先在悬浮球添加并登录 Codex 额度账号"
            case .timedOut: return "读取额度超时"
            case .noResult: return "没有可导出的额度结果"
            }
        }
    }
}
