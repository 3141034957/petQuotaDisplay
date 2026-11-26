import Foundation

enum QuotaDiagnostics {
    static func summary() -> String {
        let environment = ProcessInfo.processInfo.environment
        let codex = CodexQuotaClient.resolveCodexLaunch(environment: environment) != nil
        let gemini = QuotaCLI.find("agy", override: "ANTIGRAVITY_CLI_PATH", environment: environment) != nil
        let kimi = QuotaCLI.find("kimi", override: "KIMI_CLI_PATH", environment: environment) != nil
        return [
            "额度来源本机检查",
            "Codex：\(cliStatus(codex, override: "CODEX_CLI_PATH"))",
            "Gemini：\(cliStatus(gemini, override: "ANTIGRAVITY_CLI_PATH"))",
            "Claude Code：\(claudeStatus())",
            "OpenCode Go：在悬浮球右键菜单检查密钥设置",
            "Kimi Code：\(cliStatus(kimi, override: "KIMI_CLI_PATH"))",
        ].joined(separator: "\n")
    }

    private static func cliStatus(_ found: Bool, override variable: String) -> String {
        found ? "找到命令，登录和版本将在刷新时检查" : "未找到命令，请检查安装或 \(variable)"
    }

    private static func claudeStatus() -> String {
        do {
            let state = try ClaudeQuotaCache.read()
            return state.errorMessage == nil ? "已有状态栏额度快照" : "状态栏额度已过期，等待下次采集"
        } catch {
            return error.localizedDescription
        }
    }
}
