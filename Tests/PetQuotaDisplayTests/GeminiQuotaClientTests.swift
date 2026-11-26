import Foundation
import XCTest
@testable import PetQuotaDisplay

final class GeminiQuotaClientTests: XCTestCase {
    func testGeminiKeepsValidQuotaWhenAnotherBucketHasInvalidFields() throws {
        let data = Data("""
        {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"buckets":[
          {"id":"gemini-5h","remaining_fraction":"unknown"},
          {"id":"gemini-weekly","remaining_fraction":0.62,"reset_time":123},
          null
        ]}]}}}
        """.utf8)
        let snapshot = try GeminiQuotaClient.parseReport(data)
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 62)
        XCTAssertNil(snapshot.weekly?.resetsAt)
    }

    func testReadsSharedGeminiQuotaAndResetTimes() throws {
        let snapshot = try GeminiQuotaClient.parseReport(Data("""
            {
                "status": "SUCCESS",
                "command": {
                    "name": "usage",
                    "data": {"groups": [
                        {"name": "Gemini Models", "buckets": [
                            {"id": "gemini-weekly", "remaining_fraction": 0.624, "reset_time": "2026-11-26T16:27:26Z"},
                            {"id": "gemini-5h", "remaining_fraction": 0, "reset_time": "2026-11-20T12:50:21.125Z"}
                        ]},
                        {"name": "Claude and GPT models", "buckets": [
                            {"id": "3p-weekly", "remaining_fraction": 1},
                            {"id": "3p-5h", "remaining_fraction": 1}
                        ]}
                    ]}
                }
            }
            """.utf8))

        XCTAssertEqual(snapshot.weekly?.remainingPercent, 62)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 0)
        let weeklyReset = try XCTUnwrap(snapshot.weekly?.resetsAt)
        let shortReset = try XCTUnwrap(snapshot.fiveHour?.resetsAt)
        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(formatter.string(from: weeklyReset), "2026-11-26T16:27:26Z")
        let wholeSecond = try XCTUnwrap(formatter.date(from: "2026-11-20T12:50:21Z"))
        XCTAssertEqual(shortReset.timeIntervalSince(wholeSecond), 0.125, accuracy: 0.001)
    }

    func testSkipsUnavailableWindowsAndRejectsThirdPartyOnlyReports() throws {
        let available = report(buckets: """
            {"id":"gemini-weekly","remaining_fraction":1},
            {"id":"gemini-5h","remaining_fraction":-1}
            """)
        let snapshot = try GeminiQuotaClient.parseReport(available)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 100)
        XCTAssertNil(snapshot.weekly?.resetsAt)
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertThrowsError(try GeminiQuotaClient.parseReport(report(buckets: """
            {"id":"3p-weekly","remaining_fraction":1}, {"id":"gemini-weekly"}
            """)))
        XCTAssertThrowsError(try GeminiQuotaClient.parseReport(Data("{\"status\":\"SUCCESS\"}".utf8)))
    }

    func testVersionMustSupportReadOnlyUsageCommand() {
        for version in ["1.1.11", "1.5.10\n", "2.0.0+build"] {
            XCTAssertTrue(GeminiQuotaClient.supportsUsage(Data(version.utf8)), version)
        }
        for version in ["1.1.10", "0.9.30", "1.1.11-beta", ""] {
            XCTAssertFalse(GeminiQuotaClient.supportsUsage(Data(version.utf8)), version)
        }
    }

    private func report(buckets: String) -> Data {
        Data("""
            {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"buckets":[\(buckets)]}]}}}
            """.utf8)
    }
}
