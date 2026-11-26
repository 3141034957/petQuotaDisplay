import Foundation
import XCTest
@testable import PetQuotaDisplay

final class OpenCodeGoQuotaClientTests: XCTestCase {
    func testMalformedPeriodDoesNotDiscardTheOtherOpenCodeGoWindows() throws {
        let data = Data(#"{"usage":{"rolling":{"percent":"bad"},"weekly":{"percent":40,"resetsAt":123},"monthly":{"percent":30}}}"#.utf8)
        let snapshot = try OpenCodeGoQuotaClient.parseReport(data)
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 60)
        XCTAssertNil(snapshot.weekly?.resetsAt)
        XCTAssertEqual(snapshot.monthly?.remainingPercent, 70)
    }

    func testMapsOfficialUsageResponseToAllThreeWindows() throws {
        let now = Date(timeIntervalSince1970: 100)
        let snapshot = try OpenCodeGoQuotaClient.parseReport(UsageStub.report, now: now)
        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 70)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 0)
        XCTAssertEqual(snapshot.monthly?.remainingPercent, 50)
        XCTAssertEqual(snapshot.fetchedAt, now)
        XCTAssertEqual(snapshot.fiveHour?.resetsAt, formatter.date(from: "2026-11-21T15:00:00Z"))
        XCTAssertEqual(snapshot.weekly?.resetsAt, formatter.date(from: "2026-11-23T00:00:00Z"))
        XCTAssertNil(snapshot.monthly?.resetsAt)
    }

    func testQueriesUsageWithProvidedCredential() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UsageStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = OpenCodeGoQuotaClient(session: session, readKey: { "test-key" })
        let result = expectation(description: "usage response delivered")
        client.onResult = { response in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual((try? response.get())?.monthly?.remainingPercent, 50)
            result.fulfill()
        }
        client.refresh()
        wait(for: [result], timeout: 3)
    }

    private final class UsageStub: URLProtocol {
        static let report = Data("""
        {"usage":{
          "rolling":{"status":"ok","percent":30,"resetsAt":"2026-11-21T15:00:00.000Z"},
          "weekly":{"status":"rate-limited","percent":100,"resetsAt":"2026-11-23T00:00:00Z"},
          "monthly":{"status":"ok","percent":50,"resetsAt":null}
        }}
        """.utf8)

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            XCTAssertEqual(request.url?.absoluteString, "https://opencode.ai/inference/go/v1/usage")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.report)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
}
