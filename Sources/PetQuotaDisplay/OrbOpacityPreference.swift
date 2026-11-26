import Foundation

enum OrbOpacityPreference: Int, CaseIterable {
    case full = 100
    case high = 85
    case medium = 70

    static let defaultsKey = "orb.opacity"

    static func load(defaults: UserDefaults = QuotaPreferences.shared) -> Self {
        Self(rawValue: defaults.integer(forKey: defaultsKey)) ?? .full
    }

    var alpha: CGFloat { CGFloat(rawValue) / 100 }
    var title: String { "\(rawValue)%" }
}
