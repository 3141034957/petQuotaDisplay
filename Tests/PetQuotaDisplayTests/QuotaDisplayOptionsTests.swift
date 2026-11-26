import XCTest
@testable import PetQuotaDisplay

final class QuotaDisplayOptionsTests: XCTestCase {
    func testSourceOverrideWorksAlongsideDisplayMode() throws {
        let display = try QuotaDisplayOptions(arguments: ["--provider", "kimiCode", "--follow-codex"])
        XCTAssertEqual(display.provider, .kimiCode)
        XCTAssertEqual(display.mode, .followCodex)
        XCTAssertNil(try QuotaDisplayOptions(arguments: []).provider)
    }

    func testRejectsMissingSourceAndConflictingModes() throws {
        XCTAssertThrowsError(try QuotaDisplayOptions(arguments: ["--provider"]))
        XCTAssertThrowsError(try QuotaDisplayOptions(arguments: ["--provider", "unknown"]))
        XCTAssertThrowsError(try QuotaDisplayOptions(arguments: ["--always-show", "--follow-codex"]))
        XCTAssertThrowsError(try QuotaDisplayOptions(arguments: ["--provider", "codex", "--provider", "gemini"]))
    }

    func testAcceptsConcreteAndAdaptiveStartupPeriods() throws {
        let display = try QuotaDisplayOptions(arguments: ["--period", "monthly", "--provider", "openCodeGo"])
        XCTAssertEqual(display.period, "monthly")
        XCTAssertEqual(display.provider, .openCodeGo)
        XCTAssertEqual(try QuotaDisplayOptions(arguments: ["--period", "lowestRemaining"]).period, "lowestRemaining")
        XCTAssertThrowsError(try QuotaDisplayOptions(arguments: ["--period", "hourly"]))
    }

    func testAcceptsRefreshIntervalOverridesIncludingOff() throws {
        XCTAssertEqual(try QuotaDisplayOptions(arguments: ["--refresh-interval", "0"]).refreshCadence, .off)
        XCTAssertEqual(try QuotaDisplayOptions(arguments: ["--refresh-interval", "120"]).refreshCadence, .twoMinutes)
        XCTAssertThrowsError(try QuotaDisplayOptions(arguments: ["--refresh-interval", "-1"]))
        XCTAssertThrowsError(try QuotaDisplayOptions(arguments: ["--refresh-interval", "15"]))
    }
}
