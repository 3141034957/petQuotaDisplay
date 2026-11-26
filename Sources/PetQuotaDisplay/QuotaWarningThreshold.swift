import Foundation

enum QuotaWarningThreshold: Int, CaseIterable {
    case tenPercent = 10
    case twentyPercent = 20
    case thirtyPercent = 30
    case fortyPercent = 40

    static let defaultsKey = "quota.warningThreshold"

    static func load(defaults: UserDefaults = QuotaPreferences.shared) -> Self {
        Self(rawValue: defaults.integer(forKey: defaultsKey)) ?? .twentyPercent
    }

    var title: String { "\(rawValue)%" }

    func includes(remainingPercent: Int) -> Bool { remainingPercent <= rawValue }
}
