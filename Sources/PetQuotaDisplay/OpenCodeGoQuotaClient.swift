import Foundation
import QuotaCore

final class OpenCodeGoQuotaClient: PollingQuotaClient {
    private static let usageURL = URL(string: "https://opencode.ai/inference/go/v1/usage")!
    private static let usageSession = QuotaHTTP.makeSession()

    private let session: URLSession
    private let readKey: () throws -> String?
    private var task: URLSessionDataTask?
    private var requestID: UUID?

    var onRefreshing: (() -> Void)?
    var onResult: ((Result<QuotaSnapshot, Error>) -> Void)?

    init(session: URLSession? = nil, readKey: @escaping () throws -> String? = OpenCodeGoKeychain.read) {
        self.session = session ?? Self.usageSession
        self.readKey = readKey
    }

    func refresh() {
        guard task == nil else { return }
        onRefreshing?()

        let key: String?
        do {
            key = try readKey()
        } catch {
            onResult?(.failure(Failure.keychain))
            return
        }
        guard let key, !key.isEmpty else {
            onResult?(.failure(Failure.missingKey))
            return
        }

        let request = QuotaHTTP.request(to: Self.usageURL, token: key)
        let id = UUID()
        requestID = id
        task = session.dataTask(with: request) { [weak self] data, response, error in
            let result = Result {
                if (error as? URLError)?.code == .timedOut { throw Failure.timedOut }
                guard error == nil, let response = response as? HTTPURLResponse else {
                    throw Failure.requestFailed
                }
                switch response.statusCode {
                case 200:
                    guard let data else { throw Failure.invalidReport }
                    return try Self.parseReport(data)
                case 401: throw Failure.invalidKey
                case 403: throw Failure.noSubscription
                case 429: throw Failure.rateLimited
                default: throw Failure.requestFailed
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.requestID == id else { return }
                self.task = nil
                self.requestID = nil
                self.onResult?(result)
            }
        }
        task?.resume()
    }

    func stop() {
        requestID = nil
        task?.cancel()
        task = nil
    }

    static func parseReport(_ data: Data, now: Date = Date()) throws -> QuotaSnapshot {
        guard let report = try? JSONDecoder().decode(UsageReport.self, from: data) else {
            throw Failure.invalidReport
        }
        func quota(for bucket: UsageReport.Bucket?) -> QuotaWindow? {
            guard let bucket, (0...100).contains(bucket.percent) else { return nil }
            return QuotaWindow(usedPercent: bucket.percent, resetsAt: bucket.resetsAt.flatMap(QuotaHTTP.resetDate))
        }
        let fiveHour = quota(for: report.usage.rolling)
        let weekly = quota(for: report.usage.weekly)
        let monthly = quota(for: report.usage.monthly)
        guard fiveHour != nil || weekly != nil || monthly != nil else { throw Failure.noQuota }
        return QuotaSnapshot(planType: nil, fiveHour: fiveHour, weekly: weekly, monthly: monthly, fetchedAt: now)
    }

    private enum Failure: LocalizedError {
        case keychain, missingKey, invalidKey, noSubscription, rateLimited, timedOut, requestFailed, invalidReport, noQuota

        var errorDescription: String? {
            switch self {
            case .keychain: return "无法读取 OpenCode Go 的钥匙串密钥"
            case .missingKey: return "请在右键菜单设置 OpenCode Go API 密钥"
            case .invalidKey: return "OpenCode Go API 密钥无效，请在右键菜单重新设置"
            case .noSubscription: return "该密钥没有可用的 OpenCode Go 订阅权限"
            case .rateLimited: return "OpenCode Go 用量查询暂时受限，请稍后再试"
            case .timedOut: return "读取 OpenCode Go 额度超时"
            case .requestFailed: return "读取 OpenCode Go 额度失败"
            case .invalidReport: return "OpenCode Go 返回的额度格式无法识别"
            case .noQuota: return "OpenCode Go 未返回可用的额度周期"
            }
        }
    }

    private struct UsageReport: Decodable {
        let usage: Usage

        struct Usage: Decodable {
            let rolling: Bucket?
            let weekly: Bucket?
            let monthly: Bucket?

            private enum CodingKeys: String, CodingKey { case rolling, weekly, monthly }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                rolling = try? values.decode(Bucket.self, forKey: .rolling)
                weekly = try? values.decode(Bucket.self, forKey: .weekly)
                monthly = try? values.decode(Bucket.self, forKey: .monthly)
            }
        }

        struct Bucket: Decodable {
            let percent: Int
            let resetsAt: String?

            private enum CodingKeys: String, CodingKey { case percent, resetsAt }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                percent = try values.decode(Int.self, forKey: .percent)
                resetsAt = try? values.decode(String.self, forKey: .resetsAt)
            }
        }
    }
}
