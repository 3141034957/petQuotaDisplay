import QuotaCore

enum OrbQuotaMetric: String, CaseIterable {
    case remaining, used

    static let defaultsKey = "orb.quotaMetric"

    var title: String { self == .remaining ? "剩余百分比" : "已用百分比" }

    func percent(in window: QuotaWindow) -> Int {
        self == .remaining ? window.remainingPercent : window.usedPercent
    }
}
