import Foundation
import QuotaCore
import XCTest
@testable import PetQuotaDisplay

final class ClaudeQuotaCacheTests: XCTestCase {
    private let report = Data("""
    {
      "capturedAt": 100,
      "fiveHour": {"usedPercentage": 25.7, "resetsAt": 200},
      "sevenDay": {"usedPercentage": 0, "resetsAt": 400}
    }
    """.utf8)

    func testCachePreservesCaptureTimeAndFallsBackWhenAWindowResets() throws {
        let recent = try ClaudeQuotaCache.parse(report, now: Date(timeIntervalSince1970: 150))
        XCTAssertEqual(recent.snapshot?.fetchedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(recent.snapshot?.fiveHour?.remainingPercent, 74)
        XCTAssertEqual(recent.snapshot?.weekly?.remainingPercent, 100)

        let afterFirstReset = try ClaudeQuotaCache.parse(report, now: Date(timeIntervalSince1970: 200))
        XCTAssertNil(afterFirstReset.snapshot?.fiveHour)
        XCTAssertEqual(afterFirstReset.snapshot?.weekly?.resetsAt, Date(timeIntervalSince1970: 400))
        XCTAssertNil(afterFirstReset.errorMessage)
    }

    func testExpiredCacheRemainsAvailableAsStaleOnLaunch() throws {
        let expired = try ClaudeQuotaCache.parse(report, now: Date(timeIntervalSince1970: 401))
        guard case .stale(let snapshot, _) = expired else { return XCTFail("Expected stale quota") }
        XCTAssertEqual(snapshot.fetchedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 74)
    }

    func testPayloadWithoutQuotaDoesNotReportFullAllowance() {
        XCTAssertThrowsError(try ClaudeQuotaCache.parse(Data(#"{"capturedAt":100}"#.utf8)))
    }

    func testCacheAllowsSmallClockSkewButRejectsFarFutureCaptures() throws {
        let slightlyBehind = try ClaudeQuotaCache.parse(report, now: Date(timeIntervalSince1970: 40))
        XCTAssertNil(slightlyBehind.errorMessage)
        XCTAssertThrowsError(try ClaudeQuotaCache.parse(report, now: Date(timeIntervalSince1970: 39))) {
            XCTAssertTrue($0.localizedDescription.contains("晚于本机时间"))
        }
    }

    func testMissingResetTimeExpiresAfterTheWindowDuration() throws {
        let data = Data(#"{"capturedAt":100,"fiveHour":{"usedPercentage":20},"sevenDay":{"usedPercentage":30,"resetsAt":0}}"#.utf8)
        let afterFiveHours = try ClaudeQuotaCache.parse(data, now: Date(timeIntervalSince1970: 100 + 5 * 3_600))
        XCTAssertNil(afterFiveHours.snapshot?.fiveHour)
        XCTAssertEqual(afterFiveHours.snapshot?.weekly?.remainingPercent, 70)
        XCTAssertNil(afterFiveHours.snapshot?.weekly?.resetsAt)

        let afterSevenDays = try ClaudeQuotaCache.parse(data, now: Date(timeIntervalSince1970: 100 + 7 * 24 * 3_600))
        guard case .stale = afterSevenDays else { return XCTFail("Expected stale snapshot") }
    }

    func testMalformedBucketAndUnknownResetLeaveTheValidWindowAvailable() throws {
        let data = Data("""
        {
          "capturedAt": 100,
          "fiveHour": {"usedPercentage": "missing"},
          "sevenDay": {"usedPercentage": 30, "resetsAt": "unknown"}
        }
        """.utf8)
        let state = try ClaudeQuotaCache.parse(data, now: Date(timeIntervalSince1970: 150))
        XCTAssertNil(state.snapshot?.fiveHour)
        XCTAssertEqual(state.snapshot?.weekly?.remainingPercent, 70)
        XCTAssertNil(state.snapshot?.weekly?.resetsAt)
        XCTAssertNil(state.errorMessage)
    }
}
