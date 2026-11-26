import Darwin
import Foundation
import QuotaCore

final class GeminiQuotaClient: PollingQuotaClient {
    private enum Failure: LocalizedError {
        case missingCLI, unsupportedVersion, requestFailed, timedOut, invalidReport, noQuota

        var errorDescription: String? {
            switch self {
            case .missingCLI: return "找不到 Antigravity CLI（agy），请安装或检查 ANTIGRAVITY_CLI_PATH"
            case .unsupportedVersion: return "Gemini 额度需要 Antigravity CLI 1.1.11 或更新版本"
            case .requestFailed: return "读取 Gemini 额度失败，请在终端运行 agy 检查登录和网络"
            case .timedOut: return "读取 Gemini 额度超时"
            case .invalidReport: return "Antigravity CLI 返回的 Gemini 额度格式无法识别"
            case .noQuota: return "当前 Antigravity 账号未返回 Gemini 额度"
            }
        }
    }

    private var process: Process?
    private var timeoutWork: DispatchWorkItem?

    var onRefreshing: (() -> Void)?
    var onResult: ((Result<QuotaSnapshot, Error>) -> Void)?

    func refresh() {
        guard process == nil else { return }
        onRefreshing?()
        guard let executable = QuotaCLI.find("agy", override: "ANTIGRAVITY_CLI_PATH") else {
            onResult?(.failure(Failure.missingCLI))
            return
        }

        // Older versions can interpret /usage as a model prompt.
        run(executable, arguments: ["--version"], timeout: 5) { [weak self] version in
            guard let self else { return }
            switch version {
            case .success(let output):
                guard Self.supportsUsage(output) else {
                    self.onResult?(.failure(Failure.unsupportedVersion))
                    return
                }
                self.run(executable, arguments: ["-p", "/usage", "--output-format", "json"], timeout: 20) { [weak self] report in
                    self?.onResult?(report.flatMap { data in Result { try Self.parseReport(data) } })
                }
            case .failure(let error):
                self.onResult?(.failure(error))
            }
        }
    }

    func stop() {
        timeoutWork?.cancel()
        timeoutWork = nil
        let pending = process
        process = nil
        if let pending, pending.isRunning {
            pending.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if pending.isRunning { kill(pending.processIdentifier, SIGKILL) }
            }
        }
    }

    private func run(
        _ executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let output = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            completion(.failure(Failure.requestFailed))
            return
        }

        self.process = process
        let timeoutWork = DispatchWorkItem { [weak self, weak process] in
            guard let self, let process, self.process === process else { return }
            self.stop()
            completion(.failure(Failure.timedOut))
        }
        self.timeoutWork = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try Self.readOutput(output.fileHandleForReading) }
            if case .success = result {
                process.waitUntilExit()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.process === process else { return }
                self.stop()
                completion(result.flatMap { data in
                    process.terminationStatus == 0 ? .success(data) : .failure(Failure.requestFailed)
                })
            }
        }
    }

    private static func readOutput(_ handle: FileHandle) throws -> Data {
        let maximumBytes = 1_024 * 1_024
        var output = Data()
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            guard output.count + chunk.count <= maximumBytes else { throw Failure.invalidReport }
            output.append(chunk)
        }
        return output
    }

    static func supportsUsage(_ data: Data) -> Bool {
        let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let components = version.split(separator: "+", maxSplits: 1).first?
            .split(separator: ".", omittingEmptySubsequences: false)
        guard let components, components.count == 3,
              let major = Int(components[0]), let minor = Int(components[1]), let patch = Int(components[2]),
              major >= 0, minor >= 0, patch >= 0 else { return false }
        return (major, minor, patch) >= (1, 1, 11)
    }

    static func parseReport(_ data: Data) throws -> QuotaSnapshot {
        guard let report = try? JSONDecoder().decode(UsageReport.self, from: data),
              report.status == "SUCCESS", let command = report.command, command.name == "usage" else {
            throw Failure.invalidReport
        }
        let iso8601 = ISO8601DateFormatter()
        let iso8601WithFraction = ISO8601DateFormatter()
        iso8601WithFraction.formatOptions.insert(.withFractionalSeconds)

        var fiveHour: QuotaWindow?
        var weekly: QuotaWindow?
        for bucket in command.data.groups.flatMap(\.buckets) {
            guard let fraction = bucket.remainingFraction, (0...1).contains(fraction) else { continue }
            let resetsAt = bucket.resetTime.flatMap { iso8601.date(from: $0) ?? iso8601WithFraction.date(from: $0) }
            let quota = QuotaWindow(usedPercent: 100 - Int((fraction * 100).rounded()), resetsAt: resetsAt)
            switch bucket.id {
            case "gemini-5h": fiveHour = quota
            case "gemini-weekly": weekly = quota
            default: break
            }
        }
        guard fiveHour != nil || weekly != nil else { throw Failure.noQuota }
        return QuotaSnapshot(planType: nil, fiveHour: fiveHour, weekly: weekly)
    }

    private struct UsageReport: Decodable {
        let status: String
        let command: Command?

        struct Command: Decodable {
            let name: String
            let data: ReportData
        }

        struct ReportData: Decodable {
            let groups: [Group]
        }

        struct Group: Decodable {
            let buckets: [Bucket]
        }

        struct Bucket: Decodable {
            let id: String
            let remainingFraction: Double?
            let resetTime: String?

            enum CodingKeys: String, CodingKey {
                case id
                case remainingFraction = "remaining_fraction"
                case resetTime = "reset_time"
            }
        }
    }
}
