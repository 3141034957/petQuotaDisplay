import XCTest
@testable import PetQuotaDisplay

final class OrbResetDisplayTests: XCTestCase {
    func testCountdownKeepsResetDueAndUnknownTimesDistinct() {
        let now = Date(timeIntervalSince1970: 100)
        func label(after seconds: TimeInterval) -> String {
            OrbResetDisplay.countdownLabel(to: now.addingTimeInterval(seconds), now: now)
        }
        XCTAssertEqual(label(after: -1), "等待更新")
        XCTAssertEqual(label(after: 0), "等待更新")
        XCTAssertEqual(label(after: 59), "不到 1 分钟")
        XCTAssertEqual(label(after: 60), "1 分钟")
        XCTAssertEqual(label(after: 7_320), "2 小时 2 分")
        XCTAssertEqual(label(after: 90_000), "1 天 1 小时")
        XCTAssertEqual(label(after: .infinity), "时间未知")
    }
}
