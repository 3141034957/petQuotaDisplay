import AppKit
import Darwin
import Foundation

struct WorkspaceLaunchPlan {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let project: URL
}

struct WorkspaceLauncher {
    let store: WorkspaceStore
    var readSecret: (String) throws -> String = WorkspaceKeychain.read
    var codexHome: (CodexAccountSlot) throws -> URL? = { try CodexAccountProfile.homeURL(for: $0) }

    func open(_ instance: WorkspaceInstance, openingWith launcher: URL, completion: @escaping (Error?) -> Void) throws {
        let profile = store.instanceHome(instance.id)
        let script = profile.appendingPathComponent("Open.command")
        let command = "#!/bin/sh\nexec \(Self.quote(launcher.path)) --run-instance \(instance.id.uuidString)\n"
        try WorkspaceStore.write(Data(command.utf8), to: script, permissions: 0o700)
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app", isDirectory: true)
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    func plan(for instance: WorkspaceInstance, account: WorkspaceAccount, settings: WorkspaceSettings,
              environment base: [String: String] = ProcessInfo.processInfo.environment) throws -> WorkspaceLaunchPlan {
        let project = URL(fileURLWithPath: instance.projectPath, isDirectory: true)
        var directory: ObjCBool = false
        guard instance.projectPath.hasPrefix("/"), FileManager.default.fileExists(atPath: project.path, isDirectory: &directory),
              directory.boolValue else { throw WorkspaceError.invalidProject }
        guard instance.accountID == account.id else { throw WorkspaceError.invalidAccount }
        var environment = base
        let executable: String
        var arguments: [String]
        switch account.credential {
        case .codexLogin, .codexKey:
            let home: URL
            if account.credential == .codexLogin {
                guard let slot = CodexAccountSlot(rawValue: account.id), !slot.isPrimary,
                      let accountHome = try codexHome(slot) else { throw WorkspaceError.invalidAccount }
                home = accountHome
            } else {
                home = try store.accountHome(account.id)
                try WorkspaceStore.prepare(home)
            }
            guard let command = CodexQuotaClient.resolveCodexLaunch(environment: base) else {
                throw WorkspaceError.missingClient(.codex)
            }
            executable = command.executable
            arguments = command.arguments + ["-c", "cli_auth_credentials_store=\"file\""]
            environment["CODEX_HOME"] = home.path
            environment.removeValue(forKey: "OPENAI_API_KEY")
            environment.removeValue(forKey: "OPENAI_BASE_URL")
            environment.removeValue(forKey: "PETQUOTA_GATEWAY_KEY")
            environment.removeValue(forKey: "PETQUOTA_OPENAI_KEY")
            if let memberID = instance.gatewayMemberID {
                guard settings.gatewayMembers.contains(where: { $0.id == memberID }) else { throw WorkspaceError.invalidAccount }
                environment["PETQUOTA_GATEWAY_KEY"] = try readSecret(GatewayKeys.local(memberID))
                arguments += Self.codexProviderArguments(baseURL: "http://127.0.0.1:\(settings.gatewayPort)/v1",
                                                        key: "PETQUOTA_GATEWAY_KEY", label: "PetQuota Local Gateway")
            } else if account.credential == .codexKey {
                environment["PETQUOTA_OPENAI_KEY"] = try readSecret(account.id)
                arguments += Self.codexProviderArguments(baseURL: "https://api.openai.com/v1",
                                                        key: "PETQUOTA_OPENAI_KEY", label: "OpenAI API")
            }
        case .codeBuddyToken, .codeBuddyKey:
            guard let command = QuotaCLI.find("codebuddy", override: "CODEBUDDY_CLI_PATH", environment: base)
                ?? QuotaCLI.find("cbc", override: "CODEBUDDY_CLI_PATH", environment: base) else {
                throw WorkspaceError.missingClient(.codeBuddy)
            }
            executable = command.path
            arguments = []
            let home = store.instanceHome(instance.id).appendingPathComponent("codebuddy", isDirectory: true)
            try WorkspaceStore.prepare(home)
            for key in ["CODEBUDDY_AUTH_SESSION_FILE_DESCRIPTOR", "CODEBUDDY_AUTH_TOKEN_FILE_DESCRIPTOR",
                        "CODEBUDDY_AUTH_SNAPSHOT_PATH", "CODEBUDDY_API_KEY_FILE_DESCRIPTOR", "CODEBUDDY_AUTH_TOKEN",
                        "CODEBUDDY_API_KEY", "CODEBUDDY_BASE_URL", "CODEBUDDY_CUSTOM_HEADERS",
                        "CODEBUDDY_COPILOT_INTERNET_ENVIRONMENT", "CODEBUDDY_INTERNET_ENVIRONMENT"] {
                environment.removeValue(forKey: key)
            }
            environment["CODEBUDDY_CONFIG_DIR"] = home.path
            environment[account.credential == .codeBuddyKey ? "CODEBUDDY_API_KEY" : "CODEBUDDY_AUTH_TOKEN"] =
                try readSecret(account.id)
            if account.region == "cn" { environment["CODEBUDDY_INTERNET_ENVIRONMENT"] = "internal" }
        case .geminiLogin, .geminiKey:
            guard let command = QuotaCLI.find("gemini", override: "GEMINI_CLI_PATH", environment: base) else {
                throw WorkspaceError.missingClient(.gemini)
            }
            executable = command.path
            arguments = []
            let home = try store.accountHome(account.id)
            try WorkspaceStore.prepare(home)
            for key in ["GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_GENAI_USE_GCA",
                        "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_PROJECT_ID"] {
                environment.removeValue(forKey: key)
            }
            environment["GEMINI_CLI_HOME"] = home.path
            if account.credential == .geminiKey {
                environment["GEMINI_API_KEY"] = try readSecret(account.id)
                let preferences = home.appendingPathComponent(".gemini/settings.json")
                if !FileManager.default.fileExists(atPath: preferences.path) {
                    let auth = ["security": ["auth": ["selectedType": "gemini-api-key"]]]
                    try WorkspaceStore.write(JSONEncoder().encode(auth), to: preferences)
                }
            } else if let project = account.projectID {
                environment["GOOGLE_CLOUD_PROJECT"] = project
            }
        case .antigravity:
            guard let command = QuotaCLI.find("agy", override: "ANTIGRAVITY_CLI_PATH", environment: base) else {
                throw WorkspaceError.missingClient(.gemini)
            }
            executable = command.path
            arguments = []
        }
        let executableDirectory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        environment["PATH"] = ([executableDirectory, base["PATH"] ?? "", "/opt/homebrew/bin",
                                "/usr/local/bin", "/usr/bin", "/bin"]).joined(separator: ":")
        return WorkspaceLaunchPlan(executable: executable, arguments: arguments, environment: environment, project: project)
    }

    struct DesktopProfile {
        let project: URL
        let dataDirectory: URL
        let environment: [String: String]
    }

    func desktopProfile(_ instance: WorkspaceInstance, account: WorkspaceAccount) throws -> DesktopProfile {
        guard instance.accountID == account.id, account.credential == .codexLogin, instance.gatewayMemberID == nil,
              let slot = CodexAccountSlot(rawValue: account.id), !slot.isPrimary,
              let home = try codexHome(slot) else { throw WorkspaceError.invalidAccount }
        let project = URL(fileURLWithPath: instance.projectPath, isDirectory: true)
        guard instance.projectPath.hasPrefix("/"), try project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw WorkspaceError.invalidProject
        }
        let profile = store.instanceHome(instance.id).appendingPathComponent("electron", isDirectory: true)
        try WorkspaceStore.prepare(profile)
        return DesktopProfile(project: project, dataDirectory: profile, environment: [
            "CODEX_HOME": home.path,
            "CODEX_ELECTRON_USER_DATA_PATH": profile.path,
            "OPENAI_API_KEY": "",
            "OPENAI_BASE_URL": "",
        ])
    }

    func openCodexDesktop(_ instance: WorkspaceInstance, account: WorkspaceAccount,
                          completion: @escaping (Error?) -> Void) throws {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            throw WorkspaceError.missingDesktop
        }
        let profile = try desktopProfile(instance, account: account)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.environment = profile.environment
        configuration.arguments = ["--user-data-dir=\(profile.dataDirectory.path)"]
        NSWorkspace.shared.open([profile.project], withApplicationAt: app, configuration: configuration) { _, error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    private static func codexProviderArguments(baseURL: String, key: String, label: String) -> [String] {
        [
            "-c", "model_provider=\"petquota\"",
            "-c", "model_providers.petquota.name=\"\(label)\"",
            "-c", "model_providers.petquota.base_url=\"\(baseURL)\"",
            "-c", "model_providers.petquota.env_key=\"\(key)\"",
            "-c", "model_providers.petquota.wire_api=\"responses\"",
            "-c", "model_providers.petquota.supports_websockets=false",
            "-c", "model_providers.petquota.request_max_retries=0",
            "-c", "model_providers.petquota.stream_max_retries=0",
        ]
    }

    func run(_ id: UUID) throws -> Never {
        let settings = try store.load()
        guard let instance = settings.instances.first(where: { $0.id == id }),
              let account = WorkspaceAccountService(store: store).accounts(in: settings)
                .first(where: { $0.id == instance.accountID }) else { throw WorkspaceError.invalidAccount }
        let launch = try plan(for: instance, account: account, settings: settings)
        guard chdir(launch.project.path) == 0 else { throw WorkspaceError.invalidProject }
        var arguments = ([launch.executable] + launch.arguments).map { strdup($0) } + [nil]
        var variables = launch.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            arguments.compactMap { $0 }.forEach { free($0) }
            variables.compactMap { $0 }.forEach { free($0) }
        }
        arguments.withUnsafeMutableBufferPointer { arguments in
            variables.withUnsafeMutableBufferPointer { variables in
                _ = execve(launch.executable, arguments.baseAddress!, variables.baseAddress!)
            }
        }
        throw WorkspaceError.launchFailed
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
