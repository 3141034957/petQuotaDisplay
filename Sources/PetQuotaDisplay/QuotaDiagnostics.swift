import Foundation

enum QuotaDiagnostics {
    enum Status: String, Encodable {
        case available, needsSetup, stale, managedInApp
    }

    struct Source: Encodable {
        let id: String
        let title: String
        let status: Status
        let detail: String

        init(_ provider: QuotaProvider, status: Status, detail: String) {
            id = provider.rawValue
            title = provider.title
            self.status = status
            self.detail = detail
        }
    }

    struct Report: Encodable {
        let sources: [Source]

        var summary: String {
            (["额度来源本机检查"] + sources.map { "\($0.title)：\($0.detail)" }).joined(separator: "\n")
        }
    }

    static func checkSources() -> Report {
        let environment = ProcessInfo.processInfo.environment
        let codex = CodexQuotaClient.resolveCodexLaunch(environment: environment) != nil
        let gemini = QuotaCLI.find("agy", override: "ANTIGRAVITY_CLI_PATH", environment: environment) != nil
        let kimi = QuotaCLI.find("kimi", override: "KIMI_CLI_PATH", environment: environment) != nil
        return Report(sources: [
            cliStatus(.codex, found: codex, override: "CODEX_CLI_PATH"),
            cliStatus(.gemini, found: gemini, override: "ANTIGRAVITY_CLI_PATH"),
            claudeStatus(),
            Source(.openCodeGo, status: .managedInApp, detail: "在悬浮球右键菜单检查密钥设置"),
            cliStatus(.kimiCode, found: kimi, override: "KIMI_CLI_PATH"),
        ])
    }

    private static func cliStatus(_ provider: QuotaProvider, found: Bool, override variable: String) -> Source {
        found
            ? Source(provider, status: .available, detail: "找到命令，登录和版本将在刷新时检查")
            : Source(provider, status: .needsSetup, detail: "未找到命令，请检查安装或 \(variable)")
    }

    private static func claudeStatus() -> Source {
        do {
            let state = try ClaudeQuotaCache.read()
            if state.errorMessage == nil {
                return Source(.claudeCode, status: .available, detail: "已有状态栏额度快照")
            }
            return Source(.claudeCode, status: .stale, detail: "状态栏额度已过期，等待下次采集")
        } catch {
            return Source(.claudeCode, status: .needsSetup, detail: error.localizedDescription)
        }
    }
}
