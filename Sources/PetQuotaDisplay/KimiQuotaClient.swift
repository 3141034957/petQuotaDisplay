import Darwin
import Foundation
import QuotaCore

final class KimiQuotaClient: PollingQuotaClient {
    private static let session = QuotaHTTP.makeSession(localOnly: true)
    private let executable: () -> URL?
    private let session: URLSession
    private var server: Process?
    private var startupTimeout: DispatchWorkItem?
    private var connection: Connection?
    private var request: URLSessionDataTask?

    var onRefreshing: (() -> Void)?
    var onResult: ((Result<QuotaSnapshot, Error>) -> Void)?

    init(
        executable: @escaping () -> URL? = { QuotaCLI.find("kimi", override: "KIMI_CLI_PATH") },
        session: URLSession? = nil
    ) {
        self.executable = executable
        self.session = session ?? Self.session
    }

    func refresh() {
        guard request == nil, startupTimeout == nil else { return }
        onRefreshing?()
        if let server, server.isRunning, let connection {
            fetchUsage(from: connection, server: server)
            return
        }
        stop()
        guard let executable = executable() else {
            onResult?(.failure(Failure.missingCLI))
            return
        }
        startServer(executable)
    }

    func stop() {
        request?.cancel()
        request = nil
        startupTimeout?.cancel()
        startupTimeout = nil
        connection = nil
        let pending = server
        server = nil
        if let pending, pending.isRunning {
            pending.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if pending.isRunning { kill(pending.processIdentifier, SIGKILL) }
            }
        }
    }

    private func startServer(_ executable: URL) {
        let files = FileManager.default
        let workspace = files.temporaryDirectory.appendingPathComponent("PetQuotaDisplay-Kimi-\(UUID().uuidString)")
        do {
            try files.createDirectory(at: workspace, withIntermediateDirectories: false)
        } catch {
            onResult?(.failure(Failure.startupFailed))
            return
        }
        let output = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["web", "--json", "--host", "127.0.0.1"]
        process.currentDirectoryURL = workspace
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            try? FileManager.default.removeItem(at: workspace)
            DispatchQueue.main.async {
                guard let self, self.server === process else { return }
                let error: Failure = self.startupTimeout != nil ? .startupFailed : .serverExited
                self.stop()
                self.onResult?(.failure(error))
            }
        }
        do {
            try process.run()
        } catch {
            try? files.removeItem(at: workspace)
            onResult?(.failure(Failure.startupFailed))
            return
        }
        server = process
        let timeout = DispatchWorkItem { [weak self, weak process] in
            guard let self, let process, self.server === process else { return }
            self.stop()
            self.onResult?(.failure(Failure.startupTimedOut))
        }
        startupTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try Self.readConnection(from: output.fileHandleForReading) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.server === process else { return }
                self.startupTimeout?.cancel()
                self.startupTimeout = nil
                switch result {
                case .success(let connection):
                    self.connection = connection
                    self.fetchUsage(from: connection, server: process)
                case .failure(let error):
                    self.stop()
                    self.onResult?(.failure(error))
                }
            }
        }
    }

    private func fetchUsage(from connection: Connection, server: Process) {
        let request = QuotaHTTP.request(to: connection.usageURL, token: connection.token)
        self.request = session.dataTask(with: request) { [weak self] data, response, error in
            let result = Result {
                if (error as? URLError)?.code == .timedOut { throw Failure.requestTimedOut }
                if (response as? HTTPURLResponse)?.statusCode == 404 { throw Failure.unsupportedCLI }
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data else {
                    throw Failure.requestFailed
                }
                return try Self.parseReport(data)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.server === server else { return }
                self.request = nil
                self.onResult?(result)
            }
        }
        self.request?.resume()
    }

    private static func readConnection(from handle: FileHandle) throws -> Connection {
        var output = Data()
        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { throw Failure.startupFailed }
            let line = chunk.prefix { $0 != 0x0A }
            guard output.count + line.count <= 16_384 else { throw Failure.startupFailed }
            output.append(line)
            if line.count != chunk.count {
                return try parseConnection(output)
            }
        }
    }

    static func parseConnection(_ data: Data) throws -> Connection {
        guard let info = try? JSONDecoder().decode(StartupInfo.self, from: data),
              let origin = URLComponents(string: info.origin),
              origin.scheme == "http", origin.host == "127.0.0.1",
              let port = origin.port, (1...65_535).contains(port),
              origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              origin.path.isEmpty || origin.path == "/",
              let url = origin.url, !info.token.isEmpty, !info.token.contains(where: \.isWhitespace) else {
            throw Failure.startupFailed
        }
        return Connection(usageURL: url.appendingPathComponent("api/v1/oauth/usage"), token: info.token)
    }

    static func parseReport(_ data: Data, now: Date = Date()) throws -> QuotaSnapshot {
        guard let report = try? JSONDecoder().decode(UsageReport.self, from: data) else {
            throw Failure.invalidReport
        }
        guard report.code == 0, let usage = report.data, usage.kind == "ok" else {
            throw Failure.accountUnavailable
        }
        guard let buckets = usage.quota?.usages else { throw Failure.invalidReport }
        let fiveHour = buckets.limit5h?.window
        let weekly = buckets.limit7d?.window
        let monthly = buckets.monthCode?.window ?? buckets.monthTotal?.window
        guard fiveHour != nil || weekly != nil || monthly != nil else { throw Failure.noQuota }
        return QuotaSnapshot(planType: nil, fiveHour: fiveHour, weekly: weekly, monthly: monthly, fetchedAt: now)
    }

    struct Connection {
        let usageURL: URL
        let token: String
    }

    private struct StartupInfo: Decodable {
        let origin: String
        let token: String
    }

    private struct UsageReport: Decodable {
        let code: Int
        let data: Usage?

        struct Usage: Decodable {
            let kind: String
            let quota: Quota?
        }

        struct Quota: Decodable {
            let usages: Buckets
        }

        struct Buckets: Decodable {
            let limit5h: Bucket?
            let limit7d: Bucket?
            let monthCode: Bucket?
            let monthTotal: Bucket?
        }

        struct Bucket: Decodable {
            let usedRatio: Double
            let resetAt: String?

            var window: QuotaWindow? {
                guard (0...1).contains(usedRatio) else { return nil }
                return QuotaWindow(usedPercent: Int((usedRatio * 100).rounded()), resetsAt: resetAt.flatMap(QuotaHTTP.resetDate))
            }
        }
    }

    private enum Failure: LocalizedError {
        case missingCLI, startupFailed, startupTimedOut, serverExited, unsupportedCLI
        case requestFailed, requestTimedOut, invalidReport, accountUnavailable, noQuota

        var errorDescription: String? {
            switch self {
            case .missingCLI: return "找不到 Kimi Code CLI，请安装 kimi 或检查 KIMI_CLI_PATH"
            case .startupFailed: return "无法启动 Kimi Code 本地服务，请检查 CLI 版本"
            case .startupTimedOut: return "启动 Kimi Code 本地服务超时"
            case .serverExited: return "Kimi Code 本地服务已退出"
            case .unsupportedCLI: return "当前 Kimi Code CLI 未提供额度接口，请升级 CLI"
            case .requestFailed: return "读取 Kimi Code 额度失败"
            case .requestTimedOut: return "读取 Kimi Code 额度超时"
            case .invalidReport: return "Kimi Code 返回的额度格式无法识别"
            case .accountUnavailable: return "Kimi Code 未能读取订阅额度，请在终端运行 kimi login 检查登录"
            case .noQuota: return "当前 Kimi Code 账号未返回可用的额度周期"
            }
        }
    }
}
