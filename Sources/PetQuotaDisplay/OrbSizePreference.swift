import Foundation

enum OrbSizePreference: Int, CaseIterable {
    case compact = 90
    case standard = 111
    case large = 148

    static let defaultsKey = "orb.diameter"

    var size: CGSize { CGSize(width: rawValue, height: rawValue) }

    var title: String {
        switch self {
        case .compact: return "小"
        case .standard: return "标准"
        case .large: return "大"
        }
    }
}
