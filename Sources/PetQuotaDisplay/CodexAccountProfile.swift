import Foundation
import QuotaCore

enum CodexAccountSlot: String, CaseIterable {
    case primary
    case secondary

    var title: String {
        switch self {
        case .primary: return "当前 Codex 账号"
        case .secondary: return "备用账号"
        }
    }
}

enum CodexAccountStatus: Equatable {
    case unknown
    case stored
    case signedOut
    case signedIn(CodexAccountSummary)
}

enum CodexAccountProfile {
    static func homeURL(for slot: CodexAccountSlot) throws -> URL? {
        guard slot == .secondary else { return nil }

        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let home = applicationSupport
            .appendingPathComponent("PetQuotaDisplay", isDirectory: true)
            .appendingPathComponent("CodexAccounts", isDirectory: true)
            .appendingPathComponent(slot.rawValue, isDirectory: true)
        try fileManager.createDirectory(
            at: home,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        return home
    }

    static func hasStoredCredentials(for slot: CodexAccountSlot) -> Bool {
        guard slot == .secondary else { return true }
        guard let home = try? homeURL(for: slot) else { return false }
        return FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path)
    }
}
