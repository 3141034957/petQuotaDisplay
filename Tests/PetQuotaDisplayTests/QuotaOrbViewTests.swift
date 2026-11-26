import AppKit
import QuotaCore
import XCTest
@testable import PetQuotaDisplay

@MainActor
final class QuotaOrbViewTests: XCTestCase {
    func testStaleQuotaShowsLastUpdateAndFailureUntilRecovery() throws {
        let view = QuotaOrbView(frame: NSRect(x: 0, y: 0, width: 111, height: 111))
        let snapshot = QuotaSnapshot(
            planType: "plus",
            fiveHour: nil,
            weekly: QuotaWindow(usedPercent: 35, resetsAt: nil),
            fetchedAt: Date(timeIntervalSince1970: 123)
        )
        view.state = .loaded(snapshot)
        view.state.beginRefresh()
        XCTAssertTrue(view.toolTip?.contains("正在刷新，显示上次数据") == true)
        XCTAssertFalse(try XCTUnwrap(menu(view).item(withTitle: "立即刷新")).isEnabled)

        view.state.recordFailure("连接中断")
        let staleMenu = try menu(view)
        XCTAssertTrue(staleMenu.items.contains { $0.title.contains("剩余 65%") })
        XCTAssertTrue(staleMenu.items.contains { $0.title.hasPrefix("最后更新：") })
        XCTAssertTrue(staleMenu.items.contains { $0.title.contains("刷新失败（显示上次数据）：连接中断") })
        XCTAssertTrue(view.accessibilityLabel()?.contains("刷新失败，显示上次数据") == true)
        XCTAssertTrue(try XCTUnwrap(staleMenu.item(withTitle: "立即刷新")).isEnabled)

        view.state = .loaded(snapshot)
        XCTAssertFalse(try menu(view).items.contains { $0.title.contains("刷新失败") })
        XCTAssertFalse(view.toolTip?.contains("连接中断") == true)
    }

    func testMenuSelectionFollowsAvailableWindowAndUnavailableWindowStaysDisabled() throws {
        let view = QuotaOrbView(frame: NSRect(x: 0, y: 0, width: 111, height: 111))
        let quota = QuotaWindow(usedPercent: 10, resetsAt: nil)
        for weeklyOnly in [true, false] {
            view.state = .loaded(QuotaSnapshot(
                planType: nil,
                fiveHour: weeklyOnly ? nil : quota,
                weekly: weeklyOnly ? quota : nil
            ))
            let menu = try menu(view)
            let fiveHour = try XCTUnwrap(menu.item(withTitle: "展示 5 小时额度"))
            let weekly = try XCTUnwrap(menu.item(withTitle: "展示本周额度"))
            XCTAssertEqual(weekly.isEnabled, weeklyOnly)
            XCTAssertEqual(fiveHour.isEnabled, !weeklyOnly)
            XCTAssertEqual(weekly.state, weeklyOnly ? .on : .off)
            XCTAssertEqual(fiveHour.state, weeklyOnly ? .off : .on)
        }
    }

    func testSwitchingToGeminiClearsCodexSnapshotAndUpdatesMenu() throws {
        let view = QuotaOrbView(frame: NSRect(x: 0, y: 0, width: 111, height: 111))
        let snapshot = QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 20, resetsAt: nil))
        view.state = .loaded(snapshot)
        view.onSelectProvider = { [weak view] in view?.provider = $0 }

        let codexMenu = try menu(view)
        XCTAssertNotNil(codexMenu.item(withTitle: "切换额度账号"))
        let providers = try XCTUnwrap(codexMenu.item(withTitle: "切换额度来源")?.submenu)
        XCTAssertEqual(providers.item(withTitle: "Codex")?.state, .on)
        let gemini = try XCTUnwrap(providers.item(withTitle: "Gemini"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(gemini.action), to: gemini.target, from: gemini))

        XCTAssertNil(view.state.snapshot)
        XCTAssertEqual(view.toolTip, "Gemini 额度正在同步")
        let geminiMenu = try menu(view)
        XCTAssertNil(geminiMenu.item(withTitle: "切换额度账号"))
        XCTAssertEqual(geminiMenu.item(withTitle: "切换额度来源")?.submenu?.item(withTitle: "Gemini")?.state, .on)
        view.state = .loaded(snapshot)
        XCTAssertTrue(view.toolTip?.contains("Gemini 本周额度剩余 80%") == true)
    }

    private func menu(_ view: QuotaOrbView) throws -> NSMenu {
        let menu = try XCTUnwrap(view.menu(for: NSEvent()))
        menu.update()
        return menu
    }
}
