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
    static let selectedAccountDefaultsKey = "quota.selectedAccount"

    static func selectedAccount(in accounts: [CodexAccountSlot], defaults: UserDefaults = QuotaPreferences.shared) -> CodexAccountSlot? {
        let saved = defaults.string(forKey: selectedAccountDefaultsKey).flatMap(CodexAccountSlot.init(rawValue:))
        return saved.flatMap { accounts.contains($0) ? $0 : nil } ?? accounts.first
    }

    static func account(matching selector: String, in accounts: [CodexAccountSlot],
                        defaults: UserDefaults = QuotaPreferences.shared) throws -> CodexAccountSlot {
        if let slot = CodexAccountSlot(rawValue: selector), accounts.contains(slot) { return slot }
        let matches = accounts.filter { name(for: $0, defaults: defaults)?.caseInsensitiveCompare(selector) == .orderedSame }
        if matches.count > 1 { throw LookupError.ambiguousAccount }
        guard let first = matches.first else { throw LookupError.unknownAccount }
        return first
    }

    private enum LookupError: LocalizedError {
        case unknownAccount, ambiguousAccount

        var errorDescription: String? {
            switch self {
            case .unknownAccount: return "找不到指定的 Codex 额度账号"
            case .ambiguousAccount: return "有多个同名的 Codex 额度账号，请改用账号标识"
            }
        }
    }

    static func loadAccounts(defaults: UserDefaults = QuotaPreferences.shared,
                             persistNormalization: Bool = true) -> [CodexAccountSlot] {
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
        if persistNormalization, normalized != defaults.stringArray(forKey: additionalAccountsDefaultsKey) {
            defaults.set(normalized, forKey: additionalAccountsDefaultsKey)
        }
        return additional
    }

    static func createAccount(defaults: UserDefaults = QuotaPreferences.shared) -> CodexAccountSlot {
        let slot = CodexAccountSlot(rawValue: UUID().uuidString)!
        var accounts = loadAccounts(defaults: defaults)
        accounts.append(slot)
        defaults.set(accounts.map(\.rawValue), forKey: additionalAccountsDefaultsKey)
        return slot
    }

    static func deleteAccount(_ slot: CodexAccountSlot, defaults: UserDefaults = QuotaPreferences.shared) throws {
        guard !slot.isPrimary else { return }
        let fileManager = FileManager.default
        let home = try accountHomeURL(for: slot, create: false)
        if fileManager.fileExists(atPath: home.path) {
            try fileManager.removeItem(at: home)
        }
        let remaining = loadAccounts(defaults: defaults).filter { $0 != slot }
        defaults.set(remaining.map(\.rawValue), forKey: additionalAccountsDefaultsKey)
        defaults.removeObject(forKey: nameKey(for: slot))
        defaults.removeObject(forKey: QuotaWindowPreference.key(for: .codex, account: slot))
        defaults.removeObject(forKey: limitPreferenceKey(for: slot))
    }

    static func limitPreferenceKey(for slot: CodexAccountSlot) -> String {
        "quota.codexLimit.\(slot.rawValue)"
    }

    static func name(for slot: CodexAccountSlot, defaults: UserDefaults = QuotaPreferences.shared) -> String? {
        defaults.string(forKey: nameKey(for: slot))
    }

    static func setName(_ name: String, for slot: CodexAccountSlot, defaults: UserDefaults = QuotaPreferences.shared) {
        let singleLine = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if singleLine.isEmpty {
            defaults.removeObject(forKey: nameKey(for: slot))
        } else {
            defaults.set(String(singleLine.prefix(40)), forKey: nameKey(for: slot))
        }
    }

    private static func nameKey(for slot: CodexAccountSlot) -> String {
        "quota.accountName.\(slot.rawValue)"
    }

    static func homeURL(for slot: CodexAccountSlot, create: Bool = true) throws -> URL? {
        guard !slot.isPrimary else { return nil }
        return try accountHomeURL(for: slot, create: create)
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
