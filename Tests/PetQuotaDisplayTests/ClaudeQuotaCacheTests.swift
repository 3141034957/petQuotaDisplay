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
}
