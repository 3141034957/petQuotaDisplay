import Foundation

enum QuotaRefreshCadence: Int, CaseIterable {
    case off = 0
    case thirtySeconds = 30
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300

    static let defaultsKey = "quota.refreshCadence"

    static func load(defaults: UserDefaults = QuotaPreferences.shared) -> Self {
        guard let seconds = defaults.object(forKey: defaultsKey) as? Int else { return .thirtySeconds }
        return Self(rawValue: seconds) ?? .thirtySeconds
    }

    var interval: TimeInterval? { self == .off ? nil : TimeInterval(rawValue) }

    var title: String {
        switch self {
        case .off: return "关闭"
        case .thirtySeconds: return "30 秒"
        case .oneMinute: return "1 分钟"
        case .twoMinutes: return "2 分钟"
        case .fiveMinutes: return "5 分钟"
        }
    }
}
