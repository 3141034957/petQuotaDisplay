import Foundation
import QuotaCore

enum QuotaPreferences {
    static let selectedProviderKey = "quota.selectedProvider"
    static let menuBarEnabledKey = "quota.showsMenuBarItem"
    static let menuBarSourceNameKey = "quota.showsMenuBarSourceName"
    static let lowQuotaSoundKey = "quota.lowQuotaSound"
    static let lowQuotaNotificationKey = "quota.lowQuotaNotification"
    static let lowQuotaPeriodsKey = "quota.lowQuotaPeriods"
    static let lowQuotaPauseUntilKey = "quota.lowQuotaPauseUntil"
    static let hidesAccountEmailKey = "quota.hidesAccountEmail"
    static let orbPositionLockedKey = "orb.positionLocked"
    static let orbAllSpacesKey = "orb.showsOnAllSpaces"
    static let orbStaysOnTopKey = "orb.staysOnTop"
    static let menuBarOnlyKey = "orb.menuBarOnly"

    static let shared: UserDefaults = {
        // The standalone executable has historically used the PetQuotaDisplay domain.
        guard Bundle.main.bundleIdentifier == "com.erenshwang.petquotadisplay" else { return .standard }
        return UserDefaults(suiteName: "PetQuotaDisplay") ?? .standard
    }()

    static func selectedProvider(defaults: UserDefaults = shared) -> QuotaProvider {
        defaults.string(forKey: selectedProviderKey).flatMap(QuotaProvider.init(rawValue:)) ?? .codex
    }

    static func orbStaysOnTop(defaults: UserDefaults = shared) -> Bool {
        defaults.object(forKey: orbStaysOnTopKey) as? Bool ?? true
    }

    static func reminderPeriods(defaults: UserDefaults = shared) -> Set<QuotaPeriod> {
        guard let values = defaults.stringArray(forKey: lowQuotaPeriodsKey) else { return Set(QuotaPeriod.allCases) }
        return Set(values.compactMap(QuotaPeriod.init(rawValue:)))
    }
}
