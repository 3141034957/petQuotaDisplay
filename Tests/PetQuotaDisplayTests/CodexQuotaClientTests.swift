import XCTest
@testable import PetQuotaDisplay

final class CodexQuotaClientTests: XCTestCase {
    func testBrowserLoginURLAcceptsWebAddressesOnly() {
        let address = "https://auth.example.com/oauth?state=fixture"
        XCTAssertEqual(CodexQuotaClient.browserLoginURL(address)?.absoluteString, address)
        for invalid in ["file:///tmp/fixture", "codex://login", "https:/relative", "https://user@example.com/login"] {
            XCTAssertNil(CodexQuotaClient.browserLoginURL(invalid), invalid)
        }
    }

    func testLoginIgnoresACompletionFromAnOlderSession() throws {
        let fixture = try makeClient(scenario: "login-completion")
        defer { fixture.client.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
        let browser = expectation(description: "browser URL issued")
        let quota = expectation(description: "active login returned quota")
        var pendingStates: [Bool] = []
        fixture.client.onLoginPendingChanged = { pendingStates.append($0) }
        fixture.client.onLoginURL = { url in
            XCTAssertEqual(url.host, "auth.example.com")
            browser.fulfill()
        }
        fixture.client.onReport = { _ in quota.fulfill() }
        fixture.client.onError = { XCTFail($0.localizedDescription) }
        fixture.client.loginWithChatGPT(replacingExisting: false)
        wait(for: [browser, quota], timeout: 5, enforceOrder: true)
        XCTAssertEqual(pendingStates, [true, false])
    }

    func testCancelLoginClearsPendingStateAndReadsAccountAgain() throws {
        let fixture = try makeClient(scenario: "login-cancel")
        defer { fixture.client.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
        let signedOut = expectation(description: "account rechecked after cancellation")
        var pendingStates: [Bool] = []
        fixture.client.onLoginPendingChanged = { pendingStates.append($0) }
        fixture.client.onLoginURL = { [weak client = fixture.client] _ in client?.cancelChatGPTLogin() }
        fixture.client.onError = { XCTFail($0.localizedDescription) }
        fixture.client.onAccount = { account in
            XCTAssertNil(account)
            XCTAssertEqual(pendingStates, [true, false])
            signedOut.fulfill()
        }
        fixture.client.loginWithChatGPT(replacingExisting: false)
        wait(for: [signedOut], timeout: 5)
    }

    func testInitializationTimeoutRestartsAndRecovers() throws {
        try assertRecovers(scenario: "initialize-timeout") { error in
            guard case CodexQuotaClient.ClientError.initializationTimedOut = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testInitializationErrorRestartsAndRecovers() throws {
        try assertRecovers(scenario: "initialize-error") { error in
            XCTAssertEqual(error.localizedDescription, "fixture initialization failure")
        }
    }

    func testMalformedInitializationDoesNotMarkConnectionReady() throws {
        try assertRecovers(scenario: "initialize-malformed") { error in
            guard case CodexQuotaClient.ClientError.malformedResponse = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testClosedInputPipeReportsFailureAndRestarts() throws {
        try assertRecovers(scenario: "close-stdin") { error in
            let failure = error as NSError
            let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
            XCTAssertTrue([failure, underlying].compactMap { $0 }.contains {
                $0.domain == NSPOSIXErrorDomain && $0.code == Int(EPIPE)
            }, "Unexpected error: \(error)")
        }
    }

    func testAccountTimeoutRestartsAndRecovers() throws {
        try assertRecovers(scenario: "account-timeout") { error in
            guard case CodexQuotaClient.ClientError.requestTimedOut = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testQuotaTimeoutRestartsAndRecovers() throws {
        try assertRecovers(scenario: "quota-timeout") { error in
            guard case CodexQuotaClient.ClientError.requestTimedOut = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testUnexpectedExitRestartsAndRecovers() throws {
        try assertRecovers(scenario: "unexpected-exit") { error in
            guard case CodexQuotaClient.ClientError.processStopped = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testLateQuotaAndPushUpdateAreIgnoredAfterSignOut() throws {
        let fixture = try makeClient(scenario: "sign-out-during-read")
        defer { fixture.client.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
        let signedOut = expectation(description: "account signed out")
        let lateResult = expectation(description: "unexpected quota or restart")
        lateResult.isInverted = true
        fixture.client.onAccount = { account in
            if account == nil { signedOut.fulfill() }
        }
        fixture.client.onReport = { _ in lateResult.fulfill() }
        fixture.client.onError = { _ in lateResult.fulfill() }
        fixture.client.start()
        wait(for: [signedOut], timeout: 5)
        wait(for: [lateResult], timeout: 0.4)
    }

    func testVerifiedAccountChangeReplacesInFlightQuotaRead() throws {
        let fixture = try makeClient(scenario: "switch-during-read")
        defer { fixture.client.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
        let replacement = expectation(description: "replacement account quota")
        fixture.client.onError = { XCTFail($0.localizedDescription) }
        fixture.client.onReport = { report in
            XCTAssertEqual(report.primary.weekly?.remainingPercent, 80)
            replacement.fulfill()
        }
        fixture.client.start()
        wait(for: [replacement], timeout: 5)
    }

    func testMalformedAccountReplyDoesNotReportASignOut() throws {
        let fixture = try makeClient(scenario: "malformed-account-on-refresh")
        defer { fixture.client.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
        let invalid = expectation(description: "malformed account read reported")
        fixture.client.onAccount = { account in XCTAssertNotNil(account) }
        fixture.client.onReport = { [weak client = fixture.client] _ in client?.refresh() }
        fixture.client.onError = { error in
            guard case CodexQuotaClient.ClientError.malformedResponse = error else { return XCTFail("Unexpected error: \(error)") }
            invalid.fulfill()
        }
        fixture.client.start()
        wait(for: [invalid], timeout: 5)
    }

    func testStopCancelsScheduledRestart() throws {
        let fixture = try makeClient(scenario: "always-timeout", restartDelay: 0.2)
        defer { fixture.client.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
        let failed = expectation(description: "initialization timed out")
        fixture.client.onError = { _ in
            fixture.client.stop()
            failed.fulfill()
        }
        fixture.client.start()
        wait(for: [failed], timeout: 5)

        let settled = expectation(description: "restart deadline passed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(try String(contentsOf: fixture.counter).trimmingCharacters(in: .whitespacesAndNewlines), "1")
    }

    func testStopTerminatesAnUnresponsiveChild() throws {
        let fixture = try makeClient(scenario: "ignore-termination")
        defer { fixture.client.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
        let running = expectation(description: "fixture connected")
        fixture.client.onReport = { _ in running.fulfill() }
        fixture.client.start()
        wait(for: [running], timeout: 3)

        let pidFile = fixture.counter.appendingPathExtension("pid")
        let pidText = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidText))
        XCTAssertGreaterThan(pid, 1)
        fixture.client.stop()
        let stopped = expectation(for: NSPredicate { _, _ in kill(pid, 0) == -1 && errno == ESRCH }, evaluatedWith: nil)
        wait(for: [stopped], timeout: 4)
    }

    private func assertRecovers(scenario: String, checkError: @escaping (Error) -> Void) throws {
        let fixture = try makeClient(scenario: scenario)
        defer { fixture.client.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
        let failed = expectation(description: "failed connection reported")
        let recovered = expectation(description: "replacement connection returned quota")
        fixture.client.onError = { error in
            checkError(error)
            failed.fulfill()
        }
        fixture.client.onReport = { report in
            XCTAssertEqual(report.primary.weekly?.remainingPercent, 65)
            recovered.fulfill()
        }
        fixture.client.start()
        wait(for: [failed, recovered], timeout: 5, enforceOrder: true)
        XCTAssertEqual(try String(contentsOf: fixture.counter).trimmingCharacters(in: .whitespacesAndNewlines), "2")
    }

    private func makeClient(
        scenario: String,
        restartDelay: TimeInterval = 0.05
    ) throws -> (client: CodexQuotaClient, directory: URL, counter: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let counter = directory.appendingPathComponent("launch-count")
        let script = try XCTUnwrap(Bundle.module.url(forResource: "fake-codex", withExtension: "sh", subdirectory: "Fixtures"))
        let client = CodexQuotaClient(
            launchOverride: ("/bin/sh", [script.path, scenario, counter.path]),
            requestTimeout: 0.3,
            restartDelay: restartDelay
        )
        return (client, directory, counter)
    }
}
