import Darwin
import Foundation
import QuotaCore

final class CodexQuotaClient {
    enum ClientError: LocalizedError {
        case codexNotFound
        case processStopped(String)
        case malformedResponse
        case initializationTimedOut
        case requestTimedOut
        case loginFailed(String)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .codexNotFound:
                return "未找到 Codex CLI，请安装 codex 或检查 CODEX_CLI_PATH"
            case .processStopped(let detail):
                return detail.isEmpty ? "Codex 服务已停止" : detail
            case .malformedResponse:
                return "Codex 返回了无法识别的数据"
            case .initializationTimedOut:
                return "Codex 服务初始化超时，正在重连"
            case .requestTimedOut:
                return "Codex 额度请求超时，正在重连"
            case .loginFailed(let detail):
                return detail.isEmpty ? "ChatGPT 登录失败" : "ChatGPT 登录失败：\(detail)"
            case .server(let message):
                return message
            }
        }
    }

    var onRefreshing: (() -> Void)?
    var onReport: ((CodexQuotaReport) -> Void)?
    var onAccount: ((CodexAccountSummary?) -> Void)?
    var onLoginURL: ((URL) -> Void)?
    var onLoginPendingChanged: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?

    private enum PendingRequest: Equatable {
        case initialize
        case accountRead
        case rateLimits
        case loginStart
        case loginCancel
        case logoutThenLogin
    }

    private let queue = DispatchQueue(label: "com.petquotadisplay.codex-client")
    private let codexHome: URL?
    private let launchOverride: (executable: String, arguments: [String])?
    private let requestTimeout: TimeInterval
    private let restartDelay: TimeInterval
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private let maximumErrorBufferBytes = 64 * 1_024
    private let maximumProtocolBufferBytes = 1_024 * 1_024
    private var initialized = false
    private var verifiedAccount: CodexAccountSummary?
    private var nextRequestID = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var pendingTimeouts: [Int: DispatchWorkItem] = [:]
    private var restartWorkItem: DispatchWorkItem?
    private var isStopping = false
    private var loginWhenInitialized = false
    private var replaceLoginWhenInitialized = false
    private var activeLoginID: String?

    init(
        codexHome: URL? = nil,
        launchOverride: (executable: String, arguments: [String])? = nil,
        requestTimeout: TimeInterval = 20,
        restartDelay: TimeInterval = 5
    ) {
        self.codexHome = codexHome
        self.launchOverride = launchOverride
        self.requestTimeout = requestTimeout
        self.restartDelay = restartDelay
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
            guard let self, !self.loginWhenInitialized, self.activeLoginID == nil,
                  !self.pendingRequests.values.contains(.loginStart),
                  !self.pendingRequests.values.contains(.loginCancel),
                  !self.pendingRequests.values.contains(.logoutThenLogin) else { return }
            self.loginWhenInitialized = true
            self.replaceLoginWhenInitialized = replacingExisting
            if self.process?.isRunning != true {
                self.startLocked()
            } else if self.initialized {
                self.beginRequestedLoginLocked()
            }
        }
    }

    func cancelChatGPTLogin() {
        queue.async { [weak self] in
            guard let self, let loginID = self.activeLoginID,
                  !self.pendingRequests.values.contains(.loginCancel) else { return }
            self.sendRequestLocked(method: "account/login/cancel", params: ["loginId": loginID], kind: .loginCancel)
        }
    }

    func stop() {
        queue.sync {
            isStopping = true
            restartWorkItem?.cancel()
            restartWorkItem = nil
            cleanupLocked()
        }
    }

    private func startLocked() {
        guard process?.isRunning != true, !isStopping else { return }
        restartWorkItem?.cancel()
        restartWorkItem = nil
        cleanupLocked()
        guard let launch = launchOverride ?? Self.resolveCodexLaunch() else {
            emit(error: ClientError.codexNotFound)
            scheduleRestartLocked()
            return
        }

        errorBuffer.removeAll(keepingCapacity: true)

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

        stdout.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { [weak self, weak process] in
                guard let self, let process, self.process === process else { return }
                self.consumeOutputLocked(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { [weak self, weak process] in
                guard let self, let process, self.process === process else { return }
                self.appendErrorLocked(data)
            }
        }
        process.terminationHandler = { [weak self] stopped in
            self?.queue.async { [weak self] in
                guard let self, self.process === stopped else { return }
                self.processTerminatedLocked(status: stopped.terminationStatus)
            }
        }

        self.process = process
        do {
            guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try process.run()
            sendRequestLocked(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "pet-quota-display",
                        "title": "Codex 周额度悬浮球",
                        "version": "1.0.0",
                    ],
                    "capabilities": ["experimentalApi": true],
                ],
                kind: .initialize
            )
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
            restartAfterFailureLocked(ClientError.malformedResponse)
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
        guard let request = pendingRequests.removeValue(forKey: id) else { return }
        let timeout = pendingTimeouts.removeValue(forKey: id)
        timeout?.cancel()
        if let error = object["error"] as? [String: Any] {
            let failure = ClientError.server(Self.serverMessage(error))
            if case .initialize = request {
                restartAfterFailureLocked(failure)
            } else {
                emit(error: failure)
            }
            return
        }
        guard let result = object["result"] as? [String: Any] else {
            if case .initialize = request {
                restartAfterFailureLocked(ClientError.malformedResponse)
            } else {
                emit(error: ClientError.malformedResponse)
            }
            return
        }

        switch request {
        case .initialize:
            guard sendLocked(["method": "initialized"]) else { return }
            initialized = true
            if loginWhenInitialized {
                beginRequestedLoginLocked()
            } else {
                requestAccountLocked()
            }
        case .accountRead:
            let account = CodexAccountParser.parse(result: result)
            if verifiedAccount != account,
               let id = pendingRequests.first(where: { $0.value == .rateLimits })?.key {
                pendingRequests.removeValue(forKey: id)
                pendingTimeouts.removeValue(forKey: id)?.cancel()
            }
            verifiedAccount = account
            emit(account: account)
            requestRateLimitsLocked()
        case .rateLimits:
            do {
                let report = try QuotaParser.parseReport(result: result)
                DispatchQueue.main.async { [weak self] in self?.onReport?(report) }
            } catch {
                emit(error: error)
            }
        case .loginStart:
            guard let authURL = Self.browserLoginURL(result["authUrl"]),
                  let loginID = result["loginId"] as? String, !loginID.isEmpty else {
                emit(error: ClientError.malformedResponse)
                return
            }
            setActiveLoginLocked(loginID)
            DispatchQueue.main.async { [weak self] in self?.onLoginURL?(authURL) }
        case .loginCancel:
            guard let status = result["status"] as? String, status == "canceled" || status == "notFound" else {
                emit(error: ClientError.malformedResponse)
                return
            }
            setActiveLoginLocked(nil)
            requestAccountLocked()
        case .logoutThenLogin:
            startLoginLocked()
        }
    }

    private func requestAccountLocked() {
        guard initialized, process?.isRunning == true,
              !pendingRequests.values.contains(.accountRead) else { return }
        DispatchQueue.main.async { [weak self] in self?.onRefreshing?() }
        sendRequestLocked(method: "account/read", params: ["refreshToken": true], kind: .accountRead)
    }

    private func requestRateLimitsLocked() {
        guard initialized, verifiedAccount != nil, process?.isRunning == true,
              !pendingRequests.values.contains(.rateLimits) else { return }
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
        guard let params, let activeLoginID, params["loginId"] as? String == activeLoginID,
              let success = params["success"] as? Bool else { return }
        setActiveLoginLocked(nil)
        if success || pendingRequests.values.contains(.loginCancel) {
            requestAccountLocked()
        } else {
            emit(error: ClientError.loginFailed(params["error"] as? String ?? ""))
        }
    }

    private func setActiveLoginLocked(_ loginID: String?) {
        guard activeLoginID != loginID else { return }
        activeLoginID = loginID
        DispatchQueue.main.async { [weak self] in self?.onLoginPendingChanged?(loginID != nil) }
    }

    private func sendRequestLocked(
        method: String,
        params: Any,
        kind: PendingRequest,
        timeoutSeconds: TimeInterval? = nil
    ) {
        let id = nextIDLocked()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pendingRequests.removeValue(forKey: id) != nil else { return }
            self.pendingTimeouts.removeValue(forKey: id)
            let error: ClientError
            if case .initialize = kind {
                error = .initializationTimedOut
            } else {
                error = .requestTimedOut
            }
            self.restartAfterFailureLocked(error)
        }
        pendingRequests[id] = kind
        pendingTimeouts[id] = timeout
        queue.asyncAfter(deadline: .now() + (timeoutSeconds ?? requestTimeout), execute: timeout)
        sendLocked(["id": id, "method": method, "params": params])
    }

    private func appendErrorLocked(_ data: Data) {
        errorBuffer.append(data)
        let overflow = errorBuffer.count - maximumErrorBufferBytes
        if overflow > 0 {
            errorBuffer.removeFirst(overflow)
        }
    }

    @discardableResult
    private func sendLocked(_ object: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object),
              let input else {
            restartAfterFailureLocked(ClientError.malformedResponse)
            return false
        }
        data.append(0x0A)
        do {
            try input.write(contentsOf: data)
            return true
        } catch {
            restartAfterFailureLocked(error)
            return false
        }
    }

    private func processTerminatedLocked(status: Int32) {
        guard !isStopping else { return }
        let detail = String(data: errorBuffer, encoding: .utf8)?
            .split(separator: "\n")
            .last
            .map(String.init) ?? ""
        let message = detail.isEmpty ? "Codex 服务退出（\(status)）" : detail
        restartAfterFailureLocked(ClientError.processStopped(message))
    }

    private func restartAfterFailureLocked(_ error: Error) {
        cleanupLocked()
        guard !isStopping else { return }
        emit(error: error)
        scheduleRestartLocked()
    }

    private func scheduleRestartLocked() {
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.startLocked() }
        restartWorkItem = item
        queue.asyncAfter(deadline: .now() + restartDelay, execute: item)
    }

    private func cleanupLocked() {
        process?.terminationHandler = nil
        if let stdout = process?.standardOutput as? Pipe {
            stdout.fileHandleForReading.readabilityHandler = nil
        }
        if let stderr = process?.standardError as? Pipe {
            stderr.fileHandleForReading.readabilityHandler = nil
        }
        try? input?.close()
        input = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        initialized = false
        verifiedAccount = nil
        setActiveLoginLocked(nil)
        outputBuffer.removeAll(keepingCapacity: false)
        cancelPendingRequestsLocked()
    }

    private func cancelPendingRequestsLocked() {
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

    static func resolveCodexLaunch(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (executable: String, arguments: [String])? {
        if let cli = QuotaCLI.find("codex", override: "CODEX_CLI_PATH", environment: environment) {
            let extensionName = cli.resolvingSymlinksInPath().pathExtension.lowercased()
            let siblingNode = cli.deletingLastPathComponent().appendingPathComponent("node")
            if ["js", "mjs", "cjs"].contains(extensionName), QuotaCLI.executableURL(at: siblingNode.path) != nil {
                return (siblingNode.path, [cli.path])
            }
            return (cli.path, [])
        }
        guard environment["CODEX_CLI_PATH"] == nil else { return nil }
        for bundle in ["ChatGPT", "Codex"] {
            let path = "/Applications/\(bundle).app/Contents/Resources/codex"
            if let cli = QuotaCLI.executableURL(at: path) { return (cli.path, []) }
        }
        return nil
    }

    static func browserLoginURL(_ value: Any?) -> URL? {
        guard let address = value as? String,
              let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return components.url
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
