import XCTest
@testable import QuotaCore

final class QuotaDisplayStateTests: XCTestCase {
    private let snapshot = QuotaSnapshot(
        planType: "plus",
        fiveHour: nil,
        weekly: QuotaWindow(usedPercent: 35, resetsAt: nil),
        fetchedAt: Date(timeIntervalSince1970: 123)
    )

    func testRefreshFailureAndRetryPreserveLastSuccessfulSnapshot() {
        var state = QuotaDisplayState.loaded(snapshot)
        state.beginRefresh()
        XCTAssertEqual(state.snapshot, snapshot)
        XCTAssertTrue(state.isRefreshing)

        state.recordFailure("离线")
        XCTAssertEqual(state, .stale(snapshot, "离线"))
        XCTAssertFalse(state.isRefreshing)

        state.beginRefresh()
        XCTAssertEqual(state, .refreshing(snapshot))
        state.recordFailure("仍然离线")
        XCTAssertEqual(state.snapshot?.fetchedAt, snapshot.fetchedAt)
        XCTAssertEqual(state.errorMessage, "仍然离线")
    }

    func testFailureBeforeFirstSnapshotDoesNotInventQuota() {
        var state = QuotaDisplayState.loading
        state.recordFailure("连接失败")
        XCTAssertEqual(state, .failed("连接失败"))
        XCTAssertNil(state.snapshot)
        state.beginRefresh()
        XCTAssertEqual(state, .loading)
    }
}
