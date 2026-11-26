import Foundation

enum QuotaDiagnostics {
    struct Options {
        private(set) var provider: QuotaProvider?
        private(set) var json = false

        init(arguments: [String]) throws {
            var arguments = arguments[...]
            while let option = arguments.popFirst() {
                switch option {
                case "--provider":
                    guard provider == nil, let name = arguments.popFirst(), let source = QuotaProvider(rawValue: name) else {
                        throw InvalidOptions()
                    }
                    provider = source
                case "--json" where !json:
                    json = true
                default:
                    throw InvalidOptions()
                }
            }
        }

        private struct InvalidOptions: LocalizedError {
            var errorDescription: String? { "用法：PetQuotaDisplay --diagnose [--provider 来源] [--json]" }
        }
    }

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
        let version = QuotaBuildInformation.version
        let revision = QuotaBuildInformation.revision
        let sources: [Source]
        let display: DisplayPreferences

        var summary: String {
            let sourceLines = sources.map { "\($0.title)：\($0.detail)" }
            return ([QuotaBuildInformation.summary, "额度来源本机检查"] + sourceLines + ["", display.summary])
                .joined(separator: "\n")
        }
    }

    struct DisplayPreferences: Encodable {
        let provider: String
        let refreshIntervalSeconds: Int
        let orbDiameter: Int
        let orbOpacityPercent: Int
        let orbPositionLocked: Bool
        let orbShowsOnAllSpaces: Bool
        let showsMenuBar: Bool
        let showsOrb: Bool

        init(defaults: UserDefaults) {
            provider = QuotaPreferences.selectedProvider(defaults: defaults).rawValue
            refreshIntervalSeconds = QuotaRefreshCadence.load(defaults: defaults).rawValue
            orbDiameter = OrbSizePreference.load(defaults: defaults).rawValue
            orbOpacityPercent = OrbOpacityPreference.load(defaults: defaults).rawValue
            orbPositionLocked = defaults.bool(forKey: QuotaPreferences.orbPositionLockedKey)
            orbShowsOnAllSpaces = defaults.object(forKey: QuotaPreferences.orbAllSpacesKey) as? Bool ?? true
            showsMenuBar = defaults.bool(forKey: QuotaPreferences.menuBarEnabledKey)
            showsOrb = !showsMenuBar || !defaults.bool(forKey: QuotaPreferences.menuBarOnlyKey)
        }

        var summary: String {
            let source = QuotaProvider(rawValue: provider)?.title ?? provider
            let interval = refreshIntervalSeconds == 0 ? "关闭" : "\(refreshIntervalSeconds) 秒"
            let mode = showsOrb ? (showsMenuBar ? "悬浮球和菜单栏" : "悬浮球") : "仅菜单栏"
            let placement = orbPositionLocked ? "位置已锁定" : "允许拖动"
            let spaces = orbShowsOnAllSpaces ? "所有桌面" : "按系统桌面归属显示"
            return "保存的显示设置：\(source) · 定时刷新 \(interval) · \(mode)\n悬浮球：\(orbDiameter) pt · \(orbOpacityPercent)% 不透明度 · \(placement) · \(spaces)"
        }
    }

    static func checkSources(provider: QuotaProvider? = nil) -> Report {
        let environment = ProcessInfo.processInfo.environment
        let providers = provider.map { [$0] } ?? QuotaProvider.allCases
        let sources = providers.map { source in
            switch source {
            case .codex:
                let found = CodexQuotaClient.resolveCodexLaunch(environment: environment) != nil
                return cliStatus(source, found: found, override: "CODEX_CLI_PATH", environment: environment)
            case .gemini:
                let found = QuotaCLI.find("agy", override: "ANTIGRAVITY_CLI_PATH", environment: environment) != nil
                return cliStatus(source, found: found, override: "ANTIGRAVITY_CLI_PATH", environment: environment)
            case .claudeCode:
                return claudeStatus()
            case .openCodeGo:
                return Source(source, status: .managedInApp, detail: "在悬浮球右键菜单检查密钥设置")
            case .kimiCode:
                let found = QuotaCLI.find("kimi", override: "KIMI_CLI_PATH", environment: environment) != nil
                return cliStatus(source, found: found, override: "KIMI_CLI_PATH", environment: environment)
            }
        }
        return Report(sources: sources, display: DisplayPreferences(defaults: QuotaPreferences.shared))
    }

    private static func cliStatus(_ provider: QuotaProvider, found: Bool, override variable: String,
                                  environment: [String: String]) -> Source {
        if found {
            return Source(provider, status: .available, detail: "找到命令，登录和版本将在刷新时检查")
        }
        let detail = environment[variable] != nil
            ? "\(variable) 需要指向可执行文件的绝对路径"
            : "未找到命令，请检查安装或 \(variable)"
        return Source(provider, status: .needsSetup, detail: detail)
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
