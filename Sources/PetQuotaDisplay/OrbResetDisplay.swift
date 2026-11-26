import Foundation

enum OrbResetDisplay: String, CaseIterable {
    case time, countdown, capturedAt

    static let defaultsKey = "orb.resetDisplay"

    var title: String {
        switch self {
        case .time: return "重置时间"
        case .countdown: return "重置倒计时"
        case .capturedAt: return "最近采集时间"
        }
    }

    static func countdownLabel(to date: Date, now: Date = Date()) -> String {
        let remaining = date.timeIntervalSince(now)
        guard remaining.isFinite else { return "时间未知" }
        guard remaining > 0 else { return "等待更新" }
        guard remaining >= 60 else { return "不到 1 分钟" }
        guard remaining < 365 * 24 * 60 * 60 else { return "至少 365 天" }

        let minutes = Int(remaining / 60)
        let days = minutes / 1_440
        let hours = (minutes / 60) % 24
        if days > 0 { return hours > 0 ? "\(days) 天 \(hours) 小时" : "\(days) 天" }
        let rest = minutes % 60
        if hours > 0 { return rest > 0 ? "\(hours) 小时 \(rest) 分" : "\(hours) 小时" }
        return "\(rest) 分钟"
    }
}
