import Foundation

enum QuotaHistoryRetention: Int, CaseIterable {
    case standard = 120
    case extended = 480
    case large = 1_440

    static let defaultsKey = "quota.historyCapacity"

    static func load(defaults: UserDefaults = QuotaPreferences.shared) -> Self {
        Self(rawValue: defaults.integer(forKey: defaultsKey)) ?? .standard
    }

    var title: String { "\(rawValue) 条" }
}
