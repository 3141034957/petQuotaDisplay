import Foundation
import QuotaCore

struct CodexAccountSlot: Hashable, RawRepresentable {
    let rawValue: String

    static let primary = CodexAccountSlot(uncheckedRawValue: "primary")
    static let legacySecondary = CodexAccountSlot(uncheckedRawValue: "secondary")

    init?(rawValue: String) {
        if rawValue == Self.primary.rawValue || rawValue == Self.legacySecondary.rawValue {
            self.rawValue = rawValue
        } else if let id = UUID(uuidString: rawValue) {
            self.rawValue = id.uuidString.lowercased()
        } else {
            return nil
        }
    }

    private init(uncheckedRawValue: String) {
        self.rawValue = uncheckedRawValue
    }

    var isPrimary: Bool { self == .primary }
}

enum CodexAccountStatus: Equatable {
    case unknown
    case stored
    case signedOut
    case signedIn(CodexAccountSummary)
}

enum CodexAccountProfile {
    private static let additionalAccountsDefaultsKey = "quota.additionalAccounts"

    static func loadAccounts(defaults: UserDefaults = .standard) -> [CodexAccountSlot] {
        var seen = Set<CodexAccountSlot>()
        var additional = (defaults.stringArray(forKey: additionalAccountsDefaultsKey) ?? [])
            .compactMap(CodexAccountSlot.init(rawValue:))
            .filter { !$0.isPrimary && seen.insert($0).inserted }

        // Older versions stored one alternate login in `secondary`. Keep that login
        // visible after upgrading without moving or rewriting its credentials.
        if !additional.contains(.legacySecondary), hasStoredCredentials(for: .legacySecondary) {
            additional.append(.legacySecondary)
        }

        let normalized = additional.map(\.rawValue)
        if normalized != defaults.stringArray(forKey: additionalAccountsDefaultsKey) {
            defaults.set(normalized, forKey: additionalAccountsDefaultsKey)
        }
        return additional
    }

    static func createAccount(defaults: UserDefaults = .standard) -> CodexAccountSlot {
        let slot = CodexAccountSlot(rawValue: UUID().uuidString)!
        var accounts = loadAccounts(defaults: defaults)
        accounts.append(slot)
        defaults.set(accounts.map(\.rawValue), forKey: additionalAccountsDefaultsKey)
        return slot
    }

    static func deleteAccount(_ slot: CodexAccountSlot, defaults: UserDefaults = .standard) throws {
        guard !slot.isPrimary else { return }
        let fileManager = FileManager.default
        let home = try accountHomeURL(for: slot, create: false)
        if fileManager.fileExists(atPath: home.path) {
            try fileManager.removeItem(at: home)
        }
        let remaining = loadAccounts(defaults: defaults).filter { $0 != slot }
        defaults.set(remaining.map(\.rawValue), forKey: additionalAccountsDefaultsKey)
    }

    static func homeURL(for slot: CodexAccountSlot) throws -> URL? {
        guard !slot.isPrimary else { return nil }
        return try accountHomeURL(for: slot, create: true)
    }

    static func hasStoredCredentials(for slot: CodexAccountSlot) -> Bool {
        guard !slot.isPrimary,
              let home = try? accountHomeURL(for: slot, create: false) else { return slot.isPrimary }
        return FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path)
    }

    private static func accountHomeURL(for slot: CodexAccountSlot, create: Bool) throws -> URL {
        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        )
        let home = applicationSupport
            .appendingPathComponent("PetQuotaDisplay", isDirectory: true)
            .appendingPathComponent("CodexAccounts", isDirectory: true)
            .appendingPathComponent(slot.rawValue, isDirectory: true)
        if create {
            try fileManager.createDirectory(
                at: home,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        }
        return home
    }
}
