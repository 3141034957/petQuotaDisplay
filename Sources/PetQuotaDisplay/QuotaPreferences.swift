import Foundation

enum QuotaPreferences {
    static let selectedProviderKey = "quota.selectedProvider"
    static let menuBarEnabledKey = "quota.showsMenuBarItem"
    static let menuBarOnlyKey = "orb.menuBarOnly"

    static let shared: UserDefaults = {
        // The standalone executable has historically used the PetQuotaDisplay domain.
        guard Bundle.main.bundleIdentifier == "com.erenshwang.petquotadisplay" else { return .standard }
        return UserDefaults(suiteName: "PetQuotaDisplay") ?? .standard
    }()

    static func selectedProvider(defaults: UserDefaults = shared) -> QuotaProvider {
        defaults.string(forKey: selectedProviderKey).flatMap(QuotaProvider.init(rawValue:)) ?? .codex
    }
}
