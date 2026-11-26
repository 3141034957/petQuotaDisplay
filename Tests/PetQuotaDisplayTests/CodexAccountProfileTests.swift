import XCTest
@testable import PetQuotaDisplay

final class CodexAccountProfileTests: XCTestCase {
    func testAccountNamesAreIndependentAndCanBeReset() throws {
        let suite = "CodexAccountProfileTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = try XCTUnwrap(CodexAccountSlot(rawValue: UUID().uuidString))
        let second = try XCTUnwrap(CodexAccountSlot(rawValue: UUID().uuidString))

        CodexAccountProfile.setName("  工作\n账号  ", for: first, defaults: defaults)
        CodexAccountProfile.setName(String(repeating: "家", count: 60), for: second, defaults: defaults)
        XCTAssertEqual(CodexAccountProfile.name(for: first, defaults: defaults), "工作 账号")
        XCTAssertEqual(CodexAccountProfile.name(for: second, defaults: defaults)?.count, 40)

        CodexAccountProfile.setName(" \n ", for: first, defaults: defaults)
        XCTAssertNil(CodexAccountProfile.name(for: first, defaults: defaults))
        XCTAssertEqual(CodexAccountProfile.name(for: second, defaults: defaults)?.count, 40)
    }
}
