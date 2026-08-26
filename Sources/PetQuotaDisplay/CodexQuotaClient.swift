import Foundation
import QuotaCore

final class CodexQuotaClient {
    enum ClientError: LocalizedError {
        case codexNotFound
        case processStopped(String)
        case malformedResponse
        case requestTimedOut
        case loginFailed(String)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .codexNotFound:
                return "未找到 Codex CLI"
            case .processStopped(let detail):
                return detail.isEmpty ? "Codex 服务已停止" : detail
            case .malformedResponse:
                return "Codex 返回了无法识别的数据"
            case .requestTimedOut:
                return "Codex 额度请求超时"
            case .loginFailed(let detail):
                return detail.isEmpty ? "ChatGPT 登录失败" : "ChatGPT 登录失败：\(detail)"
            case .server(let message):
                return message
            }
        }
    }

    var onSnapshot: ((QuotaSnapshot) -> Void)?
    var onAccount: ((CodexAccountSummary?) -> Void)?
    var onLoginURL: ((URL) -> Void)?
    var onError: ((Error) -> Void)?

    private enum PendingRequest {
        case accountRead
        case rateLimits
        case loginStart
        case logoutThenLogin
    }

    private let queue = DispatchQueue(label: "com.petquotadisplay.codex-client")
    private let codexHome: URL?
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private let maximumErrorBufferBytes = 64 * 1_024
    private let maximumProtocolBufferBytes = 1_024 * 1_024
    private var initialized = false
    private var nextRequestID = 1
    private var initializeRequestID: Int?
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var pendingTimeouts: [Int: DispatchWorkItem] = [:]
    private var restartWorkItem: DispatchWorkItem?
    private var isStopping = false
    private var loginWhenInitialized = false
    private var replaceLoginWhenInitialized = false

    init(codexHome: URL? = nil) {
        self.codexHome = codexHome
    }

    func start() {
        queue.async { [weak self] in self?.startLocked() }
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.process?.isRunning != true {
                self.startLocked()
            } else if self.initialized {
                self.requestAccountLocked()
            }
        }
    }

    func loginWithChatGPT(replacingExisting: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.loginWhenInitialized = true
            self.replaceLoginWhenInitialized = replacingExisting
            if self.process?.isRunning != true {
                self.startLocked()
            } else if self.initialized {
                self.beginRequestedLoginLocked()
            }
        }
    }

    func stop() {
        queue.sync {
            isStopping = true
            restartWorkItem?.cancel()
            process?.terminationHandler = nil
            process?.terminate()
            cleanupLocked()
        }
    }

    private func startLocked() {
        guard process?.isRunning != true, !isStopping else { return }
        let launch = Self.resolveCodexLaunch()

        initialized = false
        outputBuffer.removeAll(keepingCapacity: true)
        errorBuffer.removeAll(keepingCapacity: true)
        cancelPendingReadsLocked()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        var arguments = launch.arguments
        if codexHome != nil {
            // A dedicated CODEX_HOME keeps the alternate ChatGPT session separate.
            arguments += ["-c", "cli_auth_credentials_store=\"file\""]
        }
        process.arguments = arguments + ["app-server", "--stdio"]
        if let codexHome {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = codexHome.path
            process.environment = environment
        }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        input = stdin.fileHandleForWriting

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consumeOutputLocked(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.appendErrorLocked(data) }
        }
        process.terminationHandler = { [weak self] stopped in
            self?.queue.async { self?.processTerminatedLocked(status: stopped.terminationStatus) }
        }

        do {
            try process.run()
            self.process = process
            let initializeID = nextIDLocked()
            initializeRequestID = initializeID
            sendLocked([
                "id": initializeID,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "pet-quota-display",
                        "title": "Codex 周额度悬浮球",
                        "version": "1.0.0",
                    ],
                    "capabilities": ["experimentalApi": true],
                ],
            ])
        } catch {
            cleanupLocked()
            if (error as NSError).code == NSFileNoSuchFileError {
                emit(error: ClientError.codexNotFound)
            } else {
                emit(error: error)
            }
            scheduleRestartLocked()
        }
    }

    private func consumeOutputLocked(_ data: Data) {
        outputBuffer.append(data)
        guard outputBuffer.count <= maximumProtocolBufferBytes else {
            outputBuffer.removeAll(keepingCapacity: false)
            emit(error: ClientError.malformedResponse)
            return
        }
        let newline = Data([0x0A])
        while let range = outputBuffer.range(of: newline) {
            let line = outputBuffer.subdata(in: outputBuffer.startIndex..<range.lowerBound)
            outputBuffer.removeSubrange(outputBuffer.startIndex...range.lowerBound)
            guard !line.isEmpty else { continue }
            handleLineLocked(line)
        }
    }

    private func handleLineLocked(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let method = object["method"] as? String {
            if method == "account/rateLimits/updated" {
                // This notification is sparse; refetch to get a consistent weekly snapshot.
                requestRateLimitsLocked()
            } else if method == "account/updated" {
                requestAccountLocked()
            } else if method == "account/login/completed" {
                handleLoginCompletedLocked(object["params"] as? [String: Any])
            }
            return
        }

        guard let id = Self.integer(object["id"]) else { return }
        if !initialized, id == initializeRequestID {
            if let error = object["error"] as? [String: Any] {
                emit(error: ClientError.server(Self.serverMessage(error)))
                return
            }
            initialized = true
            initializeRequestID = nil
            sendLocked(["method": "initialized"])
            if loginWhenInitialized {
                beginRequestedLoginLocked()
            } else {
                requestAccountLocked()
            }
            return
        }

        guard let request = pendingRequests.removeValue(forKey: id) else { return }
        let timeout = pendingTimeouts.removeValue(forKey: id)
        timeout?.cancel()
        if let error = object["error"] as? [String: Any] {
            emit(error: ClientError.server(Self.serverMessage(error)))
            return
        }
        guard let result = object["result"] as? [String: Any] else {
            emit(error: ClientError.malformedResponse)
            return
        }

        switch request {
        case .accountRead:
            let account = CodexAccountParser.parse(result: result)
            emit(account: account)
            if account != nil {
                requestRateLimitsLocked()
            }
        case .rateLimits:
            do {
                let snapshot = try QuotaParser.parse(result: result)
                DispatchQueue.main.async { [weak self] in self?.onSnapshot?(snapshot) }
            } catch {
                emit(error: error)
            }
        case .loginStart:
            guard let authURLString = result["authUrl"] as? String,
                  let authURL = URL(string: authURLString) else {
                emit(error: ClientError.malformedResponse)
                return
            }
            DispatchQueue.main.async { [weak self] in self?.onLoginURL?(authURL) }
        case .logoutThenLogin:
            startLoginLocked()
        }
    }

    private func requestAccountLocked() {
        guard initialized, process?.isRunning == true,
              !pendingRequests.values.contains(where: { request in
                  if case .accountRead = request { return true }
                  return false
              }) else { return }
        sendRequestLocked(method: "account/read", params: ["refreshToken": true], kind: .accountRead)
    }

    private func requestRateLimitsLocked() {
        guard initialized, process?.isRunning == true,
              !pendingRequests.values.contains(where: { request in
                  if case .rateLimits = request { return true }
                  return false
              }) else { return }
        sendRequestLocked(method: "account/rateLimits/read", params: NSNull(), kind: .rateLimits)
    }

    private func beginRequestedLoginLocked() {
        guard loginWhenInitialized else { return }
        let replacingExisting = replaceLoginWhenInitialized
        loginWhenInitialized = false
        replaceLoginWhenInitialized = false
        if replacingExisting {
            sendRequestLocked(method: "account/logout", params: NSNull(), kind: .logoutThenLogin)
        } else {
            startLoginLocked()
        }
    }

    private func startLoginLocked() {
        sendRequestLocked(
            method: "account/login/start",
            params: [
                "type": "chatgpt",
                "appBrand": "codex",
                "codexStreamlinedLogin": true,
                "useHostedLoginSuccessPage": true,
            ],
            kind: .loginStart,
            timeoutSeconds: 30
        )
    }

    private func handleLoginCompletedLocked(_ params: [String: Any]?) {
        guard let params else { return }
        if params["success"] as? Bool == true {
            requestAccountLocked()
        } else {
            emit(error: ClientError.loginFailed(params["error"] as? String ?? ""))
        }
    }

    private func sendRequestLocked(
        method: String,
        params: Any,
        kind: PendingRequest,
        timeoutSeconds: TimeInterval = 20
    ) {
        let id = nextIDLocked()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pendingRequests.removeValue(forKey: id) != nil else { return }
            self.pendingTimeouts.removeValue(forKey: id)
            self.emit(error: ClientError.requestTimedOut)
        }
        pendingRequests[id] = kind
        pendingTimeouts[id] = timeout
        queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
        sendLocked(["id": id, "method": method, "params": params])
    }

    private func appendErrorLocked(_ data: Data) {
        errorBuffer.append(data)
        let overflow = errorBuffer.count - maximumErrorBufferBytes
        if overflow > 0 {
            errorBuffer.removeFirst(overflow)
        }
    }

    private func sendLocked(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        do {
            try input?.write(contentsOf: data)
        } catch {
            emit(error: error)
        }
    }

    private func processTerminatedLocked(status: Int32) {
        guard !isStopping else { return }
        let detail = String(data: errorBuffer, encoding: .utf8)?
            .split(separator: "\n")
            .last
            .map(String.init) ?? ""
        cleanupLocked()
        let message = detail.isEmpty ? "Codex 服务退出（\(status)）" : detail
        emit(error: ClientError.processStopped(message))
        scheduleRestartLocked()
    }

    private func scheduleRestartLocked() {
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.startLocked() }
        restartWorkItem = item
        queue.asyncAfter(deadline: .now() + 5, execute: item)
    }

    private func cleanupLocked() {
        if let stdout = process?.standardOutput as? Pipe {
            stdout.fileHandleForReading.readabilityHandler = nil
        }
        if let stderr = process?.standardError as? Pipe {
            stderr.fileHandleForReading.readabilityHandler = nil
        }
        try? input?.close()
        input = nil
        process = nil
        initialized = false
        initializeRequestID = nil
        cancelPendingReadsLocked()
    }

    private func cancelPendingReadsLocked() {
        for timeout in pendingTimeouts.values {
            timeout.cancel()
        }
        pendingTimeouts.removeAll(keepingCapacity: false)
        pendingRequests.removeAll(keepingCapacity: false)
    }

    private func nextIDLocked() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func emit(error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }

    private func emit(account: CodexAccountSummary?) {
        DispatchQueue.main.async { [weak self] in self?.onAccount?(account) }
    }

    private static func resolveCodexLaunch() -> (executable: String, arguments: [String]) {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["CODEX_CLI_PATH"],
           FileManager.default.isExecutableFile(atPath: override) {
            return (override, [])
        }
        let homebrewLaunches = [
            (node: "/opt/homebrew/bin/node", codex: "/opt/homebrew/bin/codex"),
            (node: "/usr/local/bin/node", codex: "/usr/local/bin/codex"),
        ]
        for launch in homebrewLaunches {
            if FileManager.default.isExecutableFile(atPath: launch.node),
               FileManager.default.isReadableFile(atPath: launch.codex) {
                return (launch.node, [launch.codex])
            }
        }
        let bundledCodex = "/Applications/ChatGPT.app/Contents/Resources/codex"
        if FileManager.default.isExecutableFile(atPath: bundledCodex) {
            return (bundledCodex, [])
        }
        return ("/usr/bin/env", ["codex"])
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func serverMessage(_ error: [String: Any]) -> String {
        (error["message"] as? String) ?? "Codex 请求失败"
    }
}
