import Foundation
import Network
import Security

struct GatewayRequestRecord: Codable, Identifiable {
    let id: UUID
    let time: Date
    let method: String
    let path: String
    let member: String
    let model: String?
    let status: Int
    let duration: TimeInterval
    let outputBytes: Int
    var interrupted: Bool? = nil
}

struct GatewayRoute {
    let memberID: UUID
    let name: String
    let localKey: String
    let upstreamKey: String
}

enum GatewayKeys {
    static func local(_ id: UUID) -> String { "gateway-local-\(id.uuidString)" }
    static func upstream(_ id: UUID) -> String { "gateway-upstream-\(id.uuidString)" }

    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw WorkspaceError.storage }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func routes(_ members: [WorkspaceGatewayMember]) throws -> [GatewayRoute] {
        try members.map {
            let upstreamID = $0.usesAccountKey == true ? $0.codexAccountID : upstream($0.id)
            guard let upstreamID else { throw WorkspaceError.missingCredential }
            return GatewayRoute(memberID: $0.id, name: $0.name, localKey: try WorkspaceKeychain.read(local($0.id)),
                                upstreamKey: try WorkspaceKeychain.read(upstreamID))
        }
    }
}

struct GatewayHTTPRequest {
    static let maximumHeader = 32 * 1_024
    static let maximumBody = 16 * 1_024 * 1_024
    let method: String
    let path: String
    let authorization: String?
    let body: Data

    var upstreamPath: String? {
        switch (method, path) {
        case ("GET", "/v1/models"), ("POST", "/v1/responses"), ("POST", "/v1/responses/compact"),
             ("POST", "/v1/chat/completions"):
            return path
        default: return nil
        }
    }

    var model: String? {
        guard let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let model = fields["model"] as? String, model.utf8.count <= 128,
              !model.isEmpty, model.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 58, 95].contains($0)
              }) else { return nil }
        return model
    }

    struct Failure: Error {
        let status: Int
        init(_ status: Int) { self.status = status }
    }

    static func parse(_ data: Data) throws -> Self? {
        guard let end = data.range(of: Data([13, 10, 13, 10])) else {
            if data.count > maximumHeader { throw Failure(431) }
            return nil
        }
        guard end.lowerBound <= maximumHeader else { throw Failure(431) }
        guard let head = String(data: data[..<end.lowerBound], encoding: .ascii) else { throw Failure(400) }
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { throw Failure(400) }
        let request = first.split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0",
              request[1].hasPrefix("/"), !request[1].hasPrefix("//"), request[1].count <= 256 else { throw Failure(400) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { throw Failure(400) }
            let key = String(line[..<colon]).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let punctuation = "!#$%&'*+-.^`_|~".utf8
            guard !key.isEmpty, headers[key] == nil,
                  key.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || punctuation.contains($0) }),
                  value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else { throw Failure(400) }
            headers[key] = value
        }
        if headers["upgrade"] != nil { throw Failure(426) }
        if headers["expect"] != nil { throw Failure(417) }
        if headers["transfer-encoding"] != nil { throw Failure(501) }
        let length: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let parsed = Int(raw) else { throw Failure(400) }
            length = parsed
        } else {
            if request[0] == "POST" { throw Failure(411) }
            length = 0
        }
        guard length <= maximumBody else { throw Failure(413) }
        let boundary = end.upperBound + length
        guard data.count <= boundary else { throw Failure(400) }
        guard data.count == boundary else { return nil }
        return Self(method: String(request[0]), path: String(request[1]), authorization: headers["authorization"],
                    body: Data(data[end.upperBound..<boundary]))
    }
}

final class WorkspaceGateway {
    enum State: Equatable {
        case stopped, starting, ready(UInt16), failed(String)
    }

    private final class Client {
        let connection: NWConnection
        var input = Data()
        var readDeadline: DispatchWorkItem?
        var task: URLSessionDataTask?
        var record: GatewayRequestRecord?
        var bytes = 0
        var pendingWrites = 0
        var ended = false
        var cancelled = false
        var chunked = false
        var interrupted = false

        init(_ connection: NWConnection) { self.connection = connection }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate {
        weak var gateway: WorkspaceGateway?

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if gateway?.receive(response, for: dataTask) == true { completionHandler(.allow) }
            else { completionHandler(.cancel) }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            gateway?.receive(data, for: dataTask)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            gateway?.finish(task, interrupted: error != nil)
        }
    }

    private let queue = DispatchQueue(label: "com.erenshwang.petquotadisplay.gateway", qos: .userInitiated)
    private let logFile: URL
    private let makeConfiguration: () -> URLSessionConfiguration
    private var listener: NWListener?
    private var session: URLSession?
    private var routes: [String: GatewayRoute] = [:]
    private var clients: [ObjectIdentifier: Client] = [:]
    private var requests: [Int: Client] = [:]
    private var records: [GatewayRequestRecord]
    var onState: ((State) -> Void)?
    var onRecords: (([GatewayRequestRecord]) -> Void)?

    init(logFile: URL, makeConfiguration: @escaping () -> URLSessionConfiguration = { .ephemeral }) {
        self.logFile = logFile
        self.makeConfiguration = makeConfiguration
        records = Self.readRecords(from: logFile)
    }

    static func readRecords(from file: URL) -> [GatewayRequestRecord] {
        guard let data = try? Data(contentsOf: file),
              let result = try? JSONDecoder().decode([GatewayRequestRecord].self, from: data) else { return [] }
        return Array(result.prefix(200))
    }

    func start(port: UInt16, routes: [GatewayRoute]) {
        queue.async { [self] in
            guard listener == nil else { return }
            guard !routes.isEmpty, let port = NWEndpoint.Port(rawValue: port) else {
                publish(.failed("请先添加 API 网关成员。"))
                return
            }
            self.routes = Dictionary(routes.map { ($0.localKey, $0) }, uniquingKeysWith: { first, _ in first })
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            do {
                let listener = try NWListener(using: parameters)
                self.listener = listener
                let delegate = Delegate()
                delegate.gateway = self
                let configuration = makeConfiguration()
                configuration.httpShouldSetCookies = false
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.urlCache = nil
                configuration.timeoutIntervalForRequest = 300
                configuration.timeoutIntervalForResource = 900
                let operations = OperationQueue()
                operations.maxConcurrentOperationCount = 1
                operations.underlyingQueue = queue
                session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: operations)
                listener.newConnectionHandler = { [weak self] in self?.accept($0) }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.publish(.ready(listener.port?.rawValue ?? port.rawValue))
                    case .failed(let error):
                        self.stopLocked()
                        self.publish(.failed("无法启动本机网关（\(error.localizedDescription)）。"))
                    default: break
                    }
                }
                publish(.starting)
                listener.start(queue: queue)
            } catch {
                publish(.failed("无法绑定本机网关端口。"))
            }
        }
    }

    func stop() {
        queue.async { [self] in
            stopLocked()
            publish(.stopped)
        }
    }

    func updateRoutes(_ newRoutes: [GatewayRoute]) {
        queue.async { [self] in
            guard listener != nil else { return }
            routes = Dictionary(newRoutes.map { ($0.localKey, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    func removeRoute(for memberID: UUID) {
        queue.async { [self] in
            if let entry = routes.first(where: { $0.value.memberID == memberID }) {
                routes.removeValue(forKey: entry.key)
            }
        }
    }

    private func stopLocked() {
        listener?.cancel()
        listener = nil
        for client in Array(clients.values) { close(client) }
        session?.invalidateAndCancel()
        session = nil
        requests.removeAll()
        routes.removeAll()
    }

    private func publish(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onState?(state) }
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < 32 else { connection.cancel(); return }
        let client = Client(connection)
        clients[ObjectIdentifier(connection)] = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .cancelled, .failed: self.close(client)
            default: break
            }
        }
        let deadline = DispatchWorkItem { [weak self, weak client] in
            guard let self, let client else { return }
            self.reject(client, 408, "Request timed out.")
        }
        client.readDeadline = deadline
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 20, execute: deadline)
        read(client)
    }

    private func read(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak client] data, _, complete, error in
            guard let self, let client, !client.cancelled, !client.ended else { return }
            if let data { client.input.append(data) }
            do {
                if let request = try GatewayHTTPRequest.parse(client.input) {
                    client.readDeadline?.cancel()
                    client.input = Data()
                    self.forward(request, from: client)
                } else if complete || error != nil {
                    self.close(client)
                } else {
                    self.read(client)
                }
            } catch let failure as GatewayHTTPRequest.Failure {
                self.reject(client, failure.status, "Unsupported or invalid local HTTP request.")
            } catch {
                self.reject(client, 400, "Invalid HTTP request.")
            }
        }
    }

    private func forward(_ request: GatewayHTTPRequest, from client: Client) {
        if request.method == "GET", request.path == "/health" {
            reject(client, 200, "ok")
            return
        }
        guard let authorization = request.authorization, authorization.lowercased().hasPrefix("bearer "),
              let route = routes[String(authorization.dropFirst(7))] else {
            reject(client, 401, "A local gateway key is required.")
            return
        }
        guard let path = request.upstreamPath, let session else {
            reject(client, 404, "Unknown gateway route.")
            return
        }
        let url = URL(string: "https://api.openai.com\(path)")!
        var upstream = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 300)
        upstream.httpMethod = request.method
        upstream.setValue("Bearer \(route.upstreamKey)", forHTTPHeaderField: "Authorization")
        upstream.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if request.method == "POST" {
            upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
            upstream.httpBody = request.body
        }
        client.record = GatewayRequestRecord(id: UUID(), time: Date(), method: request.method, path: path, member: route.name,
                                             model: request.model, status: 0, duration: 0, outputBytes: 0)
        let task = session.dataTask(with: upstream)
        client.task = task
        requests[task.taskIdentifier] = client
        task.resume()
    }

    private func receive(_ response: URLResponse, for task: URLSessionDataTask) -> Bool {
        guard let client = requests[task.taskIdentifier], client.task === task, let record = client.record,
              let http = response as? HTTPURLResponse else { return false }
        client.record = GatewayRequestRecord(id: record.id, time: record.time, method: record.method, path: record.path,
                                             member: record.member, model: record.model, status: http.statusCode,
                                             duration: 0, outputBytes: 0)
        let upstreamType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let contentType = upstreamType.hasPrefix("text/event-stream") ? "text/event-stream" : "application/json"
        var headers = "HTTP/1.1 \(http.statusCode) Response\r\nContent-Type: \(contentType)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        client.chunked = http.statusCode >= 200 && http.statusCode != 204 && http.statusCode != 304
        if client.chunked { headers += "Transfer-Encoding: chunked\r\n" }
        if let retry = http.value(forHTTPHeaderField: "Retry-After"), !retry.contains("\r"), !retry.contains("\n") {
            headers += "Retry-After: \(retry)\r\n"
        }
        send(Data((headers + "\r\n").utf8), to: client)
        return true
    }

    private func receive(_ data: Data, for task: URLSessionDataTask) {
        guard let client = requests[task.taskIdentifier], client.task === task, client.chunked, !data.isEmpty else { return }
        client.bytes += data.count
        task.suspend()
        let chunk = Data("\(String(data.count, radix: 16))\r\n".utf8) + data + Data("\r\n".utf8)
        send(chunk, to: client) { task.resume() }
    }

    private func finish(_ task: URLSessionTask, interrupted: Bool) {
        guard let client = requests[task.taskIdentifier], client.task === task else { return }
        if client.record?.status == 0 {
            reject(client, 502, "Unable to reach the upstream API.")
        } else {
            client.ended = true
            client.interrupted = interrupted
            if client.chunked && !interrupted {
                send(Data("0\r\n\r\n".utf8), to: client)
            } else if client.pendingWrites == 0 {
                close(client)
            }
        }
    }

    private func reject(_ client: Client, _ status: Int, _ message: String) {
        guard !client.cancelled, !client.ended else { return }
        client.readDeadline?.cancel()
        let json: [String: Any] = status == 200 ? ["status": message] : ["error": ["message": message]]
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let head = "HTTP/1.1 \(status) Response\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        client.ended = true
        send(Data(head.utf8) + body, to: client)
    }

    private func send(_ data: Data, to client: Client, after: (() -> Void)? = nil) {
        client.pendingWrites += 1
        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] error in
            guard let self, let client, !client.cancelled else { return }
            client.pendingWrites -= 1
            if error != nil { self.close(client); return }
            after?()
            if client.ended && client.pendingWrites == 0 { self.close(client) }
        })
    }

    private func close(_ client: Client) {
        guard !client.cancelled else { return }
        client.cancelled = true
        client.readDeadline?.cancel()
        clients.removeValue(forKey: ObjectIdentifier(client.connection))
        if let task = client.task {
            requests.removeValue(forKey: task.taskIdentifier)
            task.cancel()
        }
        if let record = client.record {
            let status = record.status > 0 ? record.status : (client.ended ? 502 : 499)
            let finished = GatewayRequestRecord(id: record.id, time: record.time, method: record.method, path: record.path,
                                                member: record.member, model: record.model, status: status,
                                                duration: Date().timeIntervalSince(record.time), outputBytes: client.bytes,
                                                interrupted: client.interrupted || !client.ended ? true : nil)
            records.insert(finished, at: 0)
            records = Array(records.prefix(200))
            if let data = try? JSONEncoder().encode(records) { try? WorkspaceStore.write(data, to: logFile) }
            let updated = records
            DispatchQueue.main.async { [weak self] in self?.onRecords?(updated) }
        }
        client.connection.cancel()
    }
}
