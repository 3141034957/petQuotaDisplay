import Foundation
import QuotaCore

enum ClaudeQuotaCache {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/PetQuotaDisplay/claude-usage.json")
    private static let maximumClockSkew: TimeInterval = 60

    static func read() throws -> QuotaDisplayState {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw Failure.noSnapshot
        }
        return try parse(data)
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> QuotaDisplayState {
        guard let report = try? JSONDecoder().decode(Report.self, from: data),
              report.capturedAt.isFinite, report.capturedAt > 0 else {
            throw Failure.invalidSnapshot
        }
        let fetchedAt = Date(timeIntervalSince1970: report.capturedAt)
        guard fetchedAt <= now.addingTimeInterval(maximumClockSkew) else { throw Failure.futureSnapshot }
        let fiveHour = report.fiveHour?.quota
        let weekly = report.sevenDay?.quota
        guard fiveHour != nil || weekly != nil else { throw Failure.invalidSnapshot }

        func active(_ quota: QuotaWindow?, maximumAge: TimeInterval) -> QuotaWindow? {
            guard let quota else { return nil }
            let expiresAt = quota.resetsAt ?? fetchedAt.addingTimeInterval(maximumAge)
            return expiresAt > now ? quota : nil
        }
        let activeFiveHour = active(fiveHour, maximumAge: 5 * 3_600)
        let activeWeekly = active(weekly, maximumAge: 7 * 24 * 3_600)
        if activeFiveHour != nil || activeWeekly != nil {
            return .loaded(QuotaSnapshot(
                planType: nil, fiveHour: activeFiveHour, weekly: activeWeekly, fetchedAt: fetchedAt
            ))
        }
        let snapshot = QuotaSnapshot(planType: nil, fiveHour: fiveHour, weekly: weekly, fetchedAt: fetchedAt)
        return .stale(snapshot, "额度快照已过期，等待 Claude Code 提供新的状态栏数据")
    }

    private enum Failure: LocalizedError {
        case noSnapshot, invalidSnapshot, futureSnapshot

        var errorDescription: String? {
            switch self {
            case .noSnapshot: return "等待 Claude Code 状态栏数据。请按 README 接入后进行一次正常对话"
            case .invalidSnapshot: return "Claude Code 状态栏额度数据无法识别"
            case .futureSnapshot: return "Claude Code 额度采集时间晚于本机时间，等待新的状态栏数据"
            }
        }
    }

    private struct Report: Decodable {
        let capturedAt: TimeInterval
        let fiveHour: Bucket?
        let sevenDay: Bucket?

        struct Bucket: Decodable {
            let usedPercentage: Double
            let resetsAt: TimeInterval?

            var quota: QuotaWindow? {
                guard (0...100).contains(usedPercentage) else { return nil }
                let reset = resetsAt.flatMap { $0 > 0 && $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
                return QuotaWindow(
                    usedPercent: Int(usedPercentage.rounded()),
                    resetsAt: reset
                )
            }
        }
    }
}
