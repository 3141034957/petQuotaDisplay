import Darwin
import Foundation
import Security

enum WorkspacePlatform: String, Codable, CaseIterable, Identifiable {
    case codex, codeBuddy, gemini

    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: return "Codex"
        case .codeBuddy: return "CodeBuddy"
        case .gemini: return "Gemini"
        }
    }
}

enum WorkspaceCredential: String, Codable {
    case codexLogin, codexKey, codeBuddyToken, codeBuddyKey, geminiLogin, geminiKey, antigravity

    var reportsQuota: Bool {
        self != .codexKey && self != .codeBuddyKey && self != .geminiKey
    }
}

struct WorkspaceAccount: Codable, Identifiable, Equatable {
    let id: String
    let platform: WorkspacePlatform
    let name: String
    let credential: WorkspaceCredential
    var region: String? = nil
    var userID: String? = nil
    var enterpriseID: String? = nil
    var domain: String? = nil
    var projectID: String? = nil

    static let antigravity = Self(id: "antigravity-current", platform: .gemini,
                                 name: "本机 Antigravity", credential: .antigravity)
}

struct WorkspaceInstance: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let accountID: String
    let projectPath: String
    var gatewayMemberID: UUID? = nil
    var opensDesktop: Bool? = nil
}

struct WorkspaceGatewayMember: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let codexAccountID: String?
    var usesAccountKey: Bool? = nil
}

struct WorkspaceSettings: Codable {
    var accounts: [WorkspaceAccount] = []
    var instances: [WorkspaceInstance] = []
    var selectedAccounts: [String: String] = [:]
    var gatewayMembers: [WorkspaceGatewayMember] = []
    var gatewayPort: UInt16 = 14550

    func referencesAccount(_ id: String) -> Bool {
        instances.contains { $0.accountID == id } || gatewayMembers.contains { $0.codexAccountID == id }
    }
}

struct WorkspaceStore {
    static let local = Self(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/PetQuotaDisplay/Workspace", isDirectory: true))

    let directory: URL
    private var configuration: URL { directory.appendingPathComponent("settings.json") }
    var gatewayLog: URL { directory.appendingPathComponent("gateway-requests.json") }

    func load() throws -> WorkspaceSettings {
        do {
            return try JSONDecoder().decode(WorkspaceSettings.self, from: Data(contentsOf: configuration))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return WorkspaceSettings()
        }
    }

    @discardableResult
    func update(_ change: (inout WorkspaceSettings) throws -> Void) throws -> WorkspaceSettings {
        try Self.prepare(directory)
        let lock = open(directory.appendingPathComponent("settings.lock").path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw WorkspaceError.storage }
        defer { close(lock) }
        while flock(lock, LOCK_EX) != 0 {
            if errno != EINTR { throw WorkspaceError.storage }
        }
        var settings = try load()
        try change(&settings)
        try Self.write(JSONEncoder().encode(settings), to: configuration)
        return settings
    }

    func accountHome(_ id: String) throws -> URL {
        guard let uuid = UUID(uuidString: id) else { throw WorkspaceError.invalidAccount }
        return directory.appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(uuid.uuidString, isDirectory: true)
    }

    func instanceHome(_ id: UUID) -> URL {
        directory.appendingPathComponent("instances", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    static func write(_ data: Data, to file: URL, permissions: Int = 0o600) throws {
        try prepare(file.deletingLastPathComponent())
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
    }

    static func readImport(_ url: URL) throws -> Data {
        let file = url.resolvingSymlinksInPath()
        let limits = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let maximum = 2 * 1_024 * 1_024
        guard limits.isRegularFile == true, let size = limits.fileSize, size > 0, size <= maximum else {
            throw WorkspaceError.invalidAccountFile
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard let bytes = try handle.read(upToCount: maximum + 1), bytes.count <= maximum else {
            throw WorkspaceError.invalidAccountFile
        }
        return bytes
    }
}

enum WorkspaceError: LocalizedError {
    case storage, invalidAccount, invalidAccountFile, missingCredential, invalidProject, missingClient(WorkspacePlatform)
    case invalidSecret, invalidPort, gatewayNotRunning, launchFailed, missingDesktop, accountInUse, noQuota, unauthorized, quotaRequest(Int)

    var errorDescription: String? {
        switch self {
        case .storage: return "无法打开工作台资料库。"
        case .invalidAccount: return "找不到绑定的账号。"
        case .invalidAccountFile: return "此 JSON 缺少所选平台的有效登录资料。"
        case .missingCredential: return "找不到账号凭据，请重新导入或在客户端登录。"
        case .invalidProject: return "请选择已存在的本机项目目录。"
        case .missingClient(let platform): return "找不到 \(platform.title) 的命令行客户端。"
        case .invalidSecret: return "请输入有效的单行 API Key 或访问令牌。"
        case .invalidPort: return "请输入 1024 到 65535 之间的端口。"
        case .gatewayNotRunning: return "此实例绑定了 API 网关，请先启动网关。"
        case .launchFailed: return "无法打开客户端实例。"
        case .missingDesktop: return "找不到 Codex 桌面应用。可在实例设置中选择命令行客户端。"
        case .accountInUse: return "该账号仍绑定到实例或网关成员。"
        case .noQuota: return "此账号未返回可显示的额度。"
        case .unauthorized: return "登录凭据已过期或服务拒绝了授权，请更新登录资料。"
        case .quotaRequest(let status): return "额度查询失败（HTTP \(status)）。"
        }
    }
}

enum WorkspaceKeychain {
    private static func item(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.erenshwang.petquotadisplay.workspace",
         kSecAttrAccount as String: id]
    }

    static func read(_ id: String) throws -> String {
        var query = item(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw WorkspaceError.missingCredential }
        try check(status)
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw WorkspaceError.missingCredential
        }
        return secret
    }

    static func save(_ value: String, as id: String) throws {
        let query = item(id)
        let data = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, data as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query.merging(data) { _, new in new } as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    static func remove(_ id: String) throws {
        let status = SecItemDelete(item(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    static func normalizedSecret(_ value: String) throws -> String {
        let secret = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty, secret.utf8.count <= 16_384,
              secret.utf8.allSatisfy({ (33...126).contains($0) }) else { throw WorkspaceError.invalidSecret }
        return secret
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
