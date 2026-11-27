import Foundation
import QuotaCore
import XCTest
@testable import PetQuotaDisplay

final class WorkspaceTests: XCTestCase {
    func testBackgroundQuotaFailuresPreserveLastReadingOnlyWhileAuthorized() throws {
        let model = WorkspaceDashboardModel(store: WorkspaceStore(directory: temporaryWorkspace()))
        let slot = try XCTUnwrap(CodexAccountSlot(rawValue: UUID().uuidString))
        let report = try QuotaParser.parseReport(result: [
            "rateLimits": ["primary": ["usedPercent": 23, "windowDurationMins": 300]]
        ])
        model.noteCodex(slot, report: report)
        model.noteCodexFailure(slot, error: URLError(.notConnectedToInternet))
        XCTAssertEqual(model.quotas[slot.rawValue]?.values.first?.percent, 77)
        XCTAssertEqual(model.quotas[slot.rawValue]?.updatedAt, report.primary.fetchedAt)
        XCTAssertNotNil(model.quotas[slot.rawValue]?.error)
        model.noteCodexFailure(slot, error: WorkspaceError.unauthorized)
        XCTAssertEqual(model.quotas[slot.rawValue]?.values.count, 0)
        XCTAssertNil(model.quotas[slot.rawValue]?.updatedAt)
        model.noteCodex(slot, report: report)
        XCTAssertNil(model.quotas[slot.rawValue]?.error)
        XCTAssertEqual(model.quotas[slot.rawValue]?.values.first?.percent, 77)
    }

    func testSavingAnInstanceCopyPreservesTheOriginalAndItsBindings() throws {
        let directory = temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let account = WorkspaceAccount(id: UUID().uuidString, platform: .codex, name: "Codex", credential: .codexKey)
        let member = WorkspaceGatewayMember(id: UUID(), name: "Gateway", codexAccountID: account.id)
        let original = WorkspaceInstance(id: UUID(), name: "Workspace", accountID: account.id,
                                         projectPath: directory.path, gatewayMemberID: member.id, opensDesktop: false)
        try store.update {
            $0.accounts = [account]
            $0.gatewayMembers = [member]
            $0.instances = [original]
        }
        let copy = original.draftCopy()
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.gatewayMemberID, member.id)
        XCTAssertEqual(try store.load().instances, [original])
        let model = WorkspaceDashboardModel(store: store)
        XCTAssertTrue(model.saveInstance(id: copy.id, name: copy.name, accountID: copy.accountID, path: copy.projectPath,
                                         gatewayMemberID: copy.gatewayMemberID, opensDesktop: copy.opensDesktop == true))
        XCTAssertEqual(try store.load().instances, [original, copy])
    }

    func testInstanceProjectAcceptsHomeAndLocalFileLinks() throws {
        let root = temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("项目 A#1", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = WorkspaceStore(directory: root)
        let model = WorkspaceDashboardModel(store: store)
        XCTAssertTrue(model.saveInstance(id: UUID(), name: "Project", accountID: WorkspaceAccount.antigravity.id,
                                         path: project.absoluteString, gatewayMemberID: nil, opensDesktop: false))
        XCTAssertEqual(try store.load().instances.first?.projectPath, project.path)
        XCTAssertEqual(try WorkspaceInstance.projectDirectory(for: "~/").path, NSHomeDirectory())
        for invalid in ["relative/path", "file://remote.example/tmp", root.appendingPathComponent("settings.json").path] {
            XCTAssertThrowsError(try WorkspaceInstance.projectDirectory(for: invalid))
        }
    }

    func testCodexRemovalKeepsTheReadingUntilDeletionSucceeds() throws {
        let model = WorkspaceDashboardModel(store: WorkspaceStore(directory: temporaryWorkspace()))
        let slot = try XCTUnwrap(CodexAccountSlot(rawValue: UUID().uuidString))
        let account = WorkspaceAccount(id: slot.rawValue, platform: .codex, name: "Test", credential: .codexLogin)
        let report = try QuotaParser.parseReport(result: [
            "rateLimits": ["primary": ["usedPercent": 20, "windowDurationMins": 300]]
        ])
        model.noteCodex(slot, report: report)
        model.removeCodex = { XCTAssertEqual($0, slot) }
        model.deleteAccount(account)
        XCTAssertEqual(model.quotas[account.id]?.values.first?.percent, 80)
        model.removeCodex = { model.forgetQuota(for: $0.rawValue) }
        model.deleteAccount(account)
        XCTAssertNil(model.quotas[account.id])
        model.removeCodex = nil
    }

    func testRequestSearchCombinesTermsWithFailuresAndKeepsLogOrder() {
        func record(_ member: String, model: String?, status: Int, interrupted: Bool? = nil) -> GatewayRequestRecord {
            GatewayRequestRecord(id: UUID(), time: Date(), method: "POST", path: "/v1/responses", member: member,
                                 model: model, status: status, duration: 1, outputBytes: 25, interrupted: interrupted)
        }
        let complete = record("Team", model: "Model-A", status: 200)
        let limited = record("Team", model: nil, status: 429)
        let disconnected = record("Team", model: "Model-B", status: 200, interrupted: true)
        let records = [complete, limited, disconnected]
        func matches(_ query: String, failuresOnly: Bool = false) -> [UUID] {
            GatewayRequestFilter(query: query, failuresOnly: failuresOnly).apply(to: records).map(\.id)
        }
        XCTAssertEqual(matches("  "), records.map(\.id))
        XCTAssertEqual(matches(" TEAM  Responses ", failuresOnly: true), [limited.id, disconnected.id])
        XCTAssertEqual(matches("200 model-b", failuresOnly: true), [disconnected.id])
        XCTAssertEqual(matches("429"), [limited.id])
        XCTAssertTrue(matches("Model-A", failuresOnly: true).isEmpty)
    }

    func testWritesConcurrentWorkspaceEditsWithoutLosingInstances() throws {
        let directory = temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            do {
                try store.update {
                    $0.instances.append(WorkspaceInstance(id: UUID(), name: "Job \(index)",
                                                         accountID: "fixture", projectPath: "/tmp"))
                }
            } catch {
                XCTFail(error.localizedDescription)
            }
        }
        XCTAssertEqual(try store.load().instances.count, 12)
    }

    func testCodexLaunchesKeepDifferentAccountsAndProjectsSeparate() throws {
        let directory = temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let projects = ["Project Alpha", "Project Beta"].map { directory.appendingPathComponent($0) }
        for project in projects { try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false) }
        let accounts = projects.indices.map { index in
            WorkspaceAccount(id: UUID().uuidString, platform: .codex, name: "Account \(index)", credential: .codexLogin)
        }
        let instances = projects.indices.map { index in
            WorkspaceInstance(id: UUID(), name: "Codex \(index)", accountID: accounts[index].id, projectPath: projects[index].path)
        }
        let store = WorkspaceStore(directory: directory)
        let launch = WorkspaceLauncher(store: store, codexHome: { directory.appendingPathComponent($0.rawValue) })
        let env = ["CODEX_CLI_PATH": "/usr/bin/true", "OPENAI_API_KEY": "ambient-fixture"]
        let first = try launch.plan(for: instances[0], account: accounts[0], settings: WorkspaceSettings(), environment: env)
        let second = try launch.plan(for: instances[1], account: accounts[1], settings: WorkspaceSettings(), environment: env)
        XCTAssertNotEqual(first.environment["CODEX_HOME"], second.environment["CODEX_HOME"])
        XCTAssertEqual(first.project.path, projects[0].path)
        XCTAssertEqual(second.project.path, projects[1].path)
        XCTAssertNil(first.environment["OPENAI_API_KEY"])
        XCTAssertThrowsError(try launch.plan(for: instances[0], account: accounts[1], settings: WorkspaceSettings(), environment: env))
        let desktop1 = try launch.desktopProfile(instances[0], account: accounts[0])
        let desktop2 = try launch.desktopProfile(instances[1], account: accounts[1])
        XCTAssertNotEqual(desktop1.dataDirectory, desktop2.dataDirectory)
        XCTAssertEqual(desktop1.environment["CODEX_HOME"], first.environment["CODEX_HOME"])
    }

    func testGatewayBindingPassesLocalKeyThroughEnvironmentInsteadOfArguments() throws {
        let directory = temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = WorkspaceAccount(id: UUID().uuidString, platform: .codex, name: "Codex", credential: .codexKey)
        let member = WorkspaceGatewayMember(id: UUID(), name: "Route", codexAccountID: account.id, usesAccountKey: true)
        let instance = WorkspaceInstance(id: UUID(), name: "Gateway", accountID: account.id,
                                         projectPath: directory.path, gatewayMemberID: member.id)
        let runner = WorkspaceLauncher(store: WorkspaceStore(directory: directory), readSecret: { id in
            XCTAssertEqual(id, GatewayKeys.local(member.id))
            return "local-key-fixture"
        })
        let settings = WorkspaceSettings(gatewayMembers: [member], gatewayPort: 15555)
        let launch = try runner.plan(for: instance, account: account, settings: settings,
                                     environment: ["CODEX_CLI_PATH": "/usr/bin/true"])
        XCTAssertEqual(launch.environment["PETQUOTA_GATEWAY_KEY"], "local-key-fixture")
        XCTAssertFalse(launch.arguments.contains(where: { $0.contains("local-key-fixture") }))
        XCTAssertTrue(launch.arguments.contains("model_providers.petquota.base_url=\"http://127.0.0.1:15555/v1\""))
        XCTAssertNil(launch.environment["PETQUOTA_OPENAI_KEY"])
    }

    func testGeminiImportsIntoAnIsolatedProfileAndReadsPublishedModelQuota() throws {
        let directory = temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let service = WorkspaceAccountService(store: store)
        let auth = Data(#"{"access_token":"fixture-token","refresh_token":"fixture-refresh"}"#.utf8)
        let id = try service.importJSON(auth, platform: .gemini, name: "Gemini", region: "", project: "project-one")
        let account = try XCTUnwrap(store.load().accounts.first)
        XCTAssertEqual(account.id, id)
        XCTAssertEqual(account.projectID, "project-one")
        let file = try store.accountHome(id).appendingPathComponent(".gemini/oauth_creds.json")
        XCTAssertEqual(try Data(contentsOf: file), auth)
        let metadata = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((metadata[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let data = Data(#"{"buckets":[{"modelId":"gemini-test","remainingFraction":1,"tokenType":"REQUESTS"},{"modelId":"invalid","remainingFraction":false}]}"#.utf8)
        let quota = try WorkspaceAccountService.parseGemini(data)
        XCTAssertEqual(quota.map(\.title), ["gemini-test"])
        XCTAssertEqual(quota.first?.percent, 100)
    }

    func testCodeBuddyRecognizesCreditsAndUnlimitedWithoutInventingBalance() throws {
        let data = Data(#"{"code":0,"data":{"Response":{"Data":{"Accounts":[{"PackageName":"Plan","CycleCapacitySizePrecise":"200","CycleCapacityRemainPrecise":"75"},{"name":"Team","total":-1},{"name":"Unknown"}]}}}}"#.utf8)
        let quotas = try WorkspaceAccountService.parseCodeBuddy(data)
        XCTAssertEqual(quotas.map(\.title), ["Plan", "Team"])
        XCTAssertEqual(quotas[0].percent, 38)
        XCTAssertNil(quotas[1].percent)
        XCTAssertEqual(quotas[1].detail, "不限量")
        XCTAssertThrowsError(try WorkspaceAccountService.parseCodeBuddy(Data(#"{"code":42,"remaining":100}"#.utf8)))
    }

    func testGatewayRejectsAmbiguousFramingAndUnrecognizedRoutes() throws {
        func bytes(_ request: String) -> Data { Data(request.utf8) }
        let parts = bytes("POST /v1/responses HTTP/1.1\r\nContent-Length: 2\r\n\r\n{")
        XCTAssertNil(try GatewayHTTPRequest.parse(parts))
        let complete = try XCTUnwrap(GatewayHTTPRequest.parse(parts + bytes("}")))
        XCTAssertEqual(complete.upstreamPath, "/v1/responses")
        XCTAssertThrowsError(try GatewayHTTPRequest.parse(bytes(
            "POST /v1/responses HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 1\r\n\r\n{}"
        )))
        XCTAssertThrowsError(try GatewayHTTPRequest.parse(bytes(
            "POST /v1/responses HTTP/1.1\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n{}"
        )))
        XCTAssertThrowsError(try GatewayHTTPRequest.parse(bytes("GET /v1/models HTTP/1.1\r\nHost : local\r\n\r\n")))
        XCTAssertNil(try GatewayHTTPRequest.parse(bytes("GET /v1/models?proxy=example.test HTTP/1.1\r\n\r\n"))?.upstreamPath)
        XCTAssertThrowsError(try GatewayHTTPRequest.parse(bytes("GET https://example.test/ HTTP/1.1\r\n\r\n")))
    }

    @MainActor
    func testLoopbackGatewayStreamsAndRetainsOnlyRequestMetadata() async throws {
        let directory = temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let gateway = WorkspaceGateway(logFile: store.gatewayLog) {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [GatewayUpstreamStub.self]
            return config
        }
        defer { gateway.stop() }
        let bound = expectation(description: "gateway bound to loopback")
        var port: UInt16?
        gateway.onState = { state in
            if case .ready(let value) = state { port = value; bound.fulfill() }
            if case .failed(let message) = state { XCTFail(message); bound.fulfill() }
        }
        gateway.start(port: 0, routes: [
            GatewayRoute(memberID: UUID(), name: "Alpha", localKey: "local-one", upstreamKey: "upstream-one"),
            GatewayRoute(memberID: UUID(), name: "Beta", localKey: "local-two", upstreamKey: "upstream-two"),
        ])
        await fulfillment(of: [bound], timeout: 4)
        let root = try XCTUnwrap(URL(string: "http://127.0.0.1:\(try XCTUnwrap(port))"))
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        var request = URLRequest(url: root.appendingPathComponent("v1/responses"), timeoutInterval: 5)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"fixture-model","input":"not for logs","stream":true}"#.utf8)
        let (_, unauthorized) = try await client.data(for: request)
        XCTAssertEqual((unauthorized as? HTTPURLResponse)?.statusCode, 401)

        request.setValue("Bearer local-two", forHTTPHeaderField: "Authorization")
        let (stream, response) = try await client.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
        var events = stream.lines.makeAsyncIterator()
        let firstEvent = try await events.next()
        XCTAssertEqual(firstEvent, "data: beta")
        GatewayUpstreamStub.streamGate.signal()
        let finalEvent = try await events.next()
        XCTAssertEqual(finalEvent, "data: [DONE]")
        let end = try await events.next()
        XCTAssertNil(end)

        let recorded = expectation(description: "both forwarded requests written to disk")
        gateway.onRecords = { records in
            if records.count == 2 { recorded.fulfill() }
        }
        request.setValue("Bearer local-one", forHTTPHeaderField: "Authorization")
        let (_, throttled) = try await client.data(for: request)
        XCTAssertEqual((throttled as? HTTPURLResponse)?.statusCode, 429)
        XCTAssertEqual((throttled as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"), "9")
        await fulfillment(of: [recorded], timeout: 4)

        let logged = WorkspaceGateway.readRecords(from: store.gatewayLog)
        XCTAssertEqual(logged.map(\.member), ["Alpha", "Beta"])
        XCTAssertEqual(logged.map(\.status), [429, 200])
        let rawLog = try String(contentsOf: store.gatewayLog, encoding: .utf8)
        XCTAssertFalse(rawLog.contains("not for logs"))
        XCTAssertFalse(rawLog.contains("upstream-one"))
        XCTAssertFalse(rawLog.contains("local-two"))
    }

    private func temporaryWorkspace() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("petquota-tests-\(UUID())", isDirectory: true)
    }

    private final class GatewayUpstreamStub: URLProtocol {
        static let streamGate = DispatchSemaphore(value: 0)

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            XCTAssertTrue(authorization == "Bearer upstream-one" || authorization == "Bearer upstream-two")
            let success = authorization == "Bearer upstream-two"
            let headers = success ? ["Content-Type": "text/event-stream"] : ["Retry-After": "9"]
            let response = HTTPURLResponse(url: request.url!, statusCode: success ? 200 : 429,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if success {
                client?.urlProtocol(self, didLoad: Data("data: beta\n\n".utf8))
                DispatchQueue.global().async { [weak self] in
                    guard let self else { return }
                    guard Self.streamGate.wait(timeout: .now() + 4) == .success else {
                        self.client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
                        return
                    }
                    self.client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
                    self.client?.urlProtocolDidFinishLoading(self)
                }
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
        }

        override func stopLoading() {}
    }
}
