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
}
