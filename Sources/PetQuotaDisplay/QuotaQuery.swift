import Darwin
import Foundation
import QuotaCore

enum QuotaQuery {
    private typealias Stop = () -> Void

    struct Interrupted: Error {
        let signal: Int32
        var exitStatus: Int32 { 128 + signal }
    }

    static func snapshot(from provider: QuotaProvider, timeout: TimeInterval, modelID: String? = nil,
                         accountSelector: String? = nil) throws -> QuotaExport {
        try waitForResult(timeout: timeout) { complete in
            try startSnapshot(from: provider, modelID: modelID, accountSelector: accountSelector, complete: complete)
        }
    }

    static func snapshots(from providers: [QuotaProvider], timeout: TimeInterval, selecting period: String?,
                          accountSelector: String?) throws -> QuotaBatchExport {
        var results: [QuotaProvider: Result<QuotaExport, Error>] = [:]
        do {
            try waitForResult(timeout: timeout) { (finish: @escaping (Result<Void, Error>) -> Void) in
                let stops = providers.compactMap { provider -> Stop? in
                    func complete(_ result: Result<QuotaExport, Error>) {
                        guard results[provider] == nil else { return }
                        results[provider] = result.flatMap { quota in
                            Result {
                                var quota = quota
                                if let period { try quota.selectPeriod(period) }
                                return quota
                            }
                        }
                        if results.count == providers.count { finish(.success(())) }
                    }
                    do {
                        return try startSnapshot(from: provider, modelID: nil,
                                                 accountSelector: provider == .codex ? accountSelector : nil,
                                                 complete: complete)
                    } catch {
                        complete(.failure(error))
                        return nil
                    }
                }
                return { stops.forEach { $0() } }
            }
        } catch Failure.timedOut {
            // Keep results from sources that completed before the shared deadline.
        }
        let sources = providers.map { provider in
            QuotaBatchExport.Source(provider: provider, result: results[provider] ?? .failure(Failure.timedOut))
        }
        return QuotaBatchExport(sources: sources)
    }

    private static func startSnapshot(from provider: QuotaProvider, modelID: String?, accountSelector: String?,
                                      complete: @escaping (Result<QuotaExport, Error>) -> Void) throws -> Stop {
        guard modelID == nil || provider == .codex else { throw Failure.modelOnlyForCodex }
        guard accountSelector == nil || provider == .codex else { throw Failure.accountOnlyForCodex }
        func export(_ state: QuotaDisplayState) -> Result<QuotaExport, Error> {
            guard let export = QuotaExport(provider: provider, state: state) else { return .failure(Failure.noResult) }
            return .success(export)
        }
        func finishPolling(_ snapshot: Result<QuotaSnapshot, Error>) {
            complete(snapshot.flatMap { export(.loaded($0)) })
        }
        switch provider {
        case .claudeCode:
            complete(export(try ClaudeQuotaCache.read()))
            return {}
        case .codex:
            return try startCodexReport(accountSelector: accountSelector) { report in
                complete(report.flatMap { report in Result { try codexExport(from: report, modelID: modelID) } })
            }
        case .gemini:
            return start(GeminiQuotaClient(), complete: finishPolling)
        case .openCodeGo:
            let client = OpenCodeGoQuotaClient(readKey: { try OpenCodeGoKeychain.read(allowInteraction: false) })
            return start(client, complete: finishPolling)
        case .kimiCode:
            return start(KimiQuotaClient(), complete: finishPolling)
        }
    }

    static func codexReport(timeout: TimeInterval, accountSelector: String?) throws -> CodexQuotaReport {
        try waitForResult(timeout: timeout) { complete in
            try startCodexReport(accountSelector: accountSelector, complete: complete)
        }
    }

    private static func startCodexReport(accountSelector: String?,
                                         complete: @escaping (Result<CodexQuotaReport, Error>) -> Void) throws -> Stop {
        let accounts = CodexAccountProfile.loadAccounts(persistNormalization: false)
        let requested = try accountSelector.map { try CodexAccountProfile.account(matching: $0, in: accounts) }
        guard let account = requested ?? CodexAccountProfile.selectedAccount(in: accounts),
              CodexAccountProfile.hasStoredCredentials(for: account) else { throw Failure.codexAccountRequired }
        let client = CodexQuotaClient(codexHome: try CodexAccountProfile.homeURL(for: account, create: false))
        client.onAccount = { account in
            if account == nil { complete(.failure(Failure.codexAccountRequired)) }
        }
        client.onError = { complete(.failure($0)) }
        client.onReport = { complete(.success($0)) }
        client.start()
        return { client.stop() }
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

    private static func start(_ client: PollingQuotaClient, complete: @escaping (Result<QuotaSnapshot, Error>) -> Void) -> Stop {
        client.onResult = complete
        client.refresh()
        return { client.stop() }
    }

    private static func waitForResult<Value>(
        timeout: TimeInterval,
        start: (@escaping (Result<Value, Error>) -> Void) throws -> Stop
    ) throws -> Value {
        var result: Result<Value, Error>?
        var interruption: Interrupted?
        func complete(_ response: Result<Value, Error>) {
            if result == nil { result = response }
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { complete(.failure(Failure.timedOut)) }
        timer.activate()
        let signals = [SIGINT, SIGTERM].map { number in
            // Caught dispositions reset for a child process on exec.
            let previous = signal(number) { _ in }
            let listener = DispatchSource.makeSignalSource(signal: number, queue: .main)
            listener.setEventHandler {
                if interruption == nil { interruption = Interrupted(signal: number) }
            }
            listener.activate()
            return (number, previous, listener)
        }
        defer {
            for (number, previous, listener) in signals {
                listener.cancel()
                signal(number, previous)
            }
        }
        defer { timer.cancel() }
        let stop = try start(complete)
        defer {
            stop()
            QuotaChildProcess.waitForTerminations()
        }
        while result == nil, interruption == nil {
            _ = RunLoop.main.run(mode: .default, before: .distantFuture)
        }
        if let interruption { throw interruption }
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
