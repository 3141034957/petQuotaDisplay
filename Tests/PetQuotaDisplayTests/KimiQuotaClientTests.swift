import Foundation
import XCTest
@testable import PetQuotaDisplay

final class KimiQuotaClientTests: XCTestCase {
    func testParsesPublishedWindowsAndPrefersMonthlyCodingQuota() throws {
        let now = Date(timeIntervalSince1970: 100)
        let snapshot = try KimiQuotaClient.parseReport(UsageStub.report, now: now)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 76)
        XCTAssertNil(snapshot.weekly)
        XCTAssertEqual(snapshot.monthly?.remainingPercent, 65)
        XCTAssertEqual(snapshot.fetchedAt, now)
        XCTAssertEqual(
            snapshot.fiveHour?.resetsAt,
            ISO8601DateFormatter().date(from: "2026-11-28T12:00:00Z")
        )

        let legacyReport = Data(#"{"code":0,"data":{"kind":"ok","quota":{"usages":{"limit7d":{"usedRatio":0.5},"monthTotal":{"usedRatio":0.25}}}}}"#.utf8)
        let legacy = try KimiQuotaClient.parseReport(legacyReport)
        XCTAssertEqual(legacy.weekly?.remainingPercent, 50)
        XCTAssertEqual(legacy.monthly?.remainingPercent, 75)
    }

    func testRejectsAnUpstreamFailureWithHTTP200() {
        let report = Data(#"{"code":0,"data":{"kind":"error","message":"No managed account"}}"#.utf8)
        XCTAssertThrowsError(try KimiQuotaClient.parseReport(report))
    }

    func testInvalidKimiCodingPeriodFallsBackToValidMonthlyTotal() throws {
        let report = Data("""
        {"code":0,"data":{"kind":"ok","quota":{"usages":{
          "limit5h":{"usedRatio":0.24,"resetAt":123},
          "limit7d":{"usedRatio":"bad"},
          "monthCode":"unavailable",
          "monthTotal":{"usedRatio":0.8}
        }}}}
        """.utf8)
        let snapshot = try KimiQuotaClient.parseReport(report)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 76)
        XCTAssertNil(snapshot.fiveHour?.resetsAt)
        XCTAssertNil(snapshot.weekly)
        XCTAssertEqual(snapshot.monthly?.remainingPercent, 20)
    }

    func testOnlyAcceptsLoopbackOriginForBearerToken() throws {
        let origin = try KimiQuotaClient.parseConnection(Data(#"{"origin":"http://127.0.0.1:58627","token":"local-token"}"#.utf8))
        XCTAssertEqual(origin.usageURL.absoluteString, "http://127.0.0.1:58627/api/v1/oauth/usage")

        for address in ["https://example.com:58627", "http://127.0.0.1@example.com:58627", "http://127.0.0.1:58627/base"] {
            let data = try JSONEncoder().encode(["origin": address, "token": "local-token"])
            XCTAssertThrowsError(try KimiQuotaClient.parseConnection(data), address)
        }
    }

    func testStartsOneLocalServerAndReusesItForRefresh() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("kimi-quota-\(UUID().uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("kimi")
        try """
        #!/bin/sh
        [ "$*" = "web --json --host 127.0.0.1" ] || exit 1
        printf '%s\\n' "$$" >> "$0.starts"
        printf '%s\\n' '{"origin":"http://127.0.0.1:58627","token":"local-token"}'
        /bin/dd if=/dev/zero bs=65536 count=16 2>/dev/null
        : > "$0.ready"
        exec /bin/sleep 15

        """.write(to: executable, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UsageStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = KimiQuotaClient(executable: { executable }, session: session)
        defer { client.stop() }

        let first = expectation(description: "initial Kimi quota")
        client.onResult = { response in
            XCTAssertEqual((try? response.get())?.monthly?.remainingPercent, 65)
            first.fulfill()
        }
        client.refresh()
        wait(for: [first], timeout: 5)

        let readyFile = directory.appendingPathComponent("kimi.ready")
        let drained = expectation(for: NSPredicate { _, _ in files.fileExists(atPath: readyFile.path) }, evaluatedWith: nil)
        wait(for: [drained], timeout: 3)

        let second = expectation(description: "renewed Kimi quota")
        client.onResult = { response in
            XCTAssertEqual((try? response.get())?.monthly?.remainingPercent, 65)
            second.fulfill()
        }
        client.refresh()
        wait(for: [second], timeout: 5)
        let launches = try String(contentsOf: directory.appendingPathComponent("kimi.starts"), encoding: .utf8)
        XCTAssertEqual(launches.split(separator: "\n").count, 1)
    }

    private final class UsageStub: URLProtocol {
        static let report = Data("""
        {"code":0,"data":{"kind":"ok","quota":{"usages":{
          "limit5h":{"usedRatio":0.24,"resetAt":"2026-11-28T20:00:00.000+08:00"},
          "monthCode":{"usedRatio":0.35},
          "monthTotal":{"usedRatio":0.8}
        }}}}
        """.utf8)

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:58627/api/v1/oauth/usage")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-token")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.report)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
}
