import Foundation

struct QuotaWarningThreshold: RawRepresentable, Equatable {
    let rawValue: Int

    static let twentyPercent = Self(preset: 20)
    static let thirtyPercent = Self(preset: 30)
    static let presets = [Self(preset: 10), twentyPercent, thirtyPercent, Self(preset: 40)]

    static let defaultsKey = "quota.warningThreshold"

    init?(rawValue: Int) {
        guard (0...100).contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    private init(preset: Int) { rawValue = preset }

    static func load(defaults: UserDefaults = QuotaPreferences.shared) -> Self {
        guard let percent = defaults.object(forKey: defaultsKey) as? Int else { return .twentyPercent }
        return Self(rawValue: percent) ?? .twentyPercent
    }

    var title: String { "\(rawValue)%" }

    func includes(remainingPercent: Int) -> Bool { remainingPercent <= rawValue }
}
