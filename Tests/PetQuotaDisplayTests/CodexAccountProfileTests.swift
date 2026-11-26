import XCTest
@testable import PetQuotaDisplay

final class CodexAccountProfileTests: XCTestCase {
    func testQueryResolvesAnAccountIDOrUniqueName() throws {
        let suite = "CodexAccountLookupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = try XCTUnwrap(CodexAccountSlot(rawValue: UUID().uuidString))
        let second = try XCTUnwrap(CodexAccountSlot(rawValue: UUID().uuidString))
        let accounts = [first, second]
        CodexAccountProfile.setName("Work", for: second, defaults: defaults)
        XCTAssertEqual(try CodexAccountProfile.account(matching: "work", in: accounts, defaults: defaults), second)
        XCTAssertEqual(try CodexAccountProfile.account(matching: first.rawValue.uppercased(), in: accounts, defaults: defaults), first)
        CodexAccountProfile.setName("Work", for: first, defaults: defaults)
        XCTAssertThrowsError(try CodexAccountProfile.account(matching: "work", in: accounts, defaults: defaults))
        XCTAssertThrowsError(try CodexAccountProfile.account(matching: "missing", in: accounts, defaults: defaults))
    }

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
