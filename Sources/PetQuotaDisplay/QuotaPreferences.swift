import Foundation

enum QuotaPreferences {
    static let shared: UserDefaults = {
        // The standalone executable has historically used the PetQuotaDisplay domain.
        guard Bundle.main.bundleIdentifier == "com.erenshwang.petquotadisplay" else { return .standard }
        return UserDefaults(suiteName: "PetQuotaDisplay") ?? .standard
    }()
}
