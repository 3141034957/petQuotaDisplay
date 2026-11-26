import AppKit
import QuotaCore
import XCTest
@testable import PetQuotaDisplay

@MainActor
final class QuotaOrbViewTests: XCTestCase {
    func testAccessibilityPressRefreshesWhenReady() {
        let view = QuotaOrbView(frame: .zero)
        var refreshes = 0
        view.onRefresh = { refreshes += 1 }
        XCTAssertFalse(view.accessibilityPerformPress())
        view.state = .failed("连接中断")
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertEqual(refreshes, 1)
    }

    func testRefreshCadenceMenuSelectsOffWithoutDisablingManualRefresh() throws {
        let view = QuotaOrbView(frame: .zero)
        view.state = .failed("连接中断")
        view.onSelectRefreshCadence = { [weak view] in view?.refreshCadence = $0 }
        let initial = try XCTUnwrap(menu(view).item(withTitle: "定时刷新")?.submenu)
        XCTAssertEqual(initial.item(withTitle: "30 秒")?.state, .on)
        let off = try XCTUnwrap(initial.item(withTitle: "关闭"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(off.action), to: off.target, from: off))

        let updated = try menu(view)
        XCTAssertEqual(updated.item(withTitle: "定时刷新")?.submenu?.item(withTitle: "关闭")?.state, .on)
        XCTAssertTrue(try XCTUnwrap(updated.item(withTitle: "立即刷新")).isEnabled)
    }

    func testOrbMenuOffersThreeSizesAndSendsSelectedValue() throws {
        let view = QuotaOrbView(frame: .zero)
        view.onSelectSize = { [weak view] in view?.sizePreference = $0 }
        let sizes = try XCTUnwrap(menu(view).item(withTitle: "悬浮球大小")?.submenu)
        XCTAssertEqual(sizes.items.map(\.title), ["小", "标准", "大"])
        XCTAssertEqual(sizes.item(withTitle: "标准")?.state, .on)

        let large = try XCTUnwrap(sizes.item(withTitle: "大"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(large.action), to: large.target, from: large))
        XCTAssertEqual(view.sizePreference, .large)
        XCTAssertEqual(try menu(view).item(withTitle: "悬浮球大小")?.submenu?.item(withTitle: "大")?.state, .on)
    }

    func testMenuBarTitleReflectsSelectedQuotaAndRefreshStatus() {
        let view = QuotaOrbView(frame: .zero)
        let snapshot = QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 20, resetsAt: nil))
        XCTAssertEqual(view.menuBarTitle, "额度…")
        view.state = .loaded(snapshot)
        XCTAssertEqual(view.menuBarTitle, "80%")
        view.state.beginRefresh()
        XCTAssertEqual(view.menuBarTitle, "80%…")
        view.state.recordFailure("连接中断")
        XCTAssertEqual(view.menuBarTitle, "~80%")
        view.state = .failed("需要登录")
        XCTAssertEqual(view.menuBarTitle, "额度 —")
    }

    func testMenuBarOnlyModeKeepsAnActionForRestoringTheOrb() throws {
        let view = QuotaOrbView(frame: .zero)
        XCTAssertNil(try menu(view).item(withTitle: "仅在菜单栏显示"))
        view.showsMenuBarQuota = true
        view.onToggleOrbVisibility = { [weak view] in view?.menuBarOnly.toggle() }

        let hide = try XCTUnwrap(menu(view).item(withTitle: "仅在菜单栏显示"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(hide.action), to: hide.target, from: hide))
        let show = try XCTUnwrap(menu(view).item(withTitle: "显示悬浮球"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(show.action), to: show.target, from: show))
        XCTAssertFalse(view.menuBarOnly)
    }

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

    func testProvidersRememberIndependentPeriodsAndHonorLegacyPreference() throws {
        let suite = "QuotaOrbViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("fiveHour", forKey: "quota.displayedWindow")
        let view = QuotaOrbView(frame: .zero, defaults: defaults)
        let quota = QuotaWindow(usedPercent: 10, resetsAt: nil)
        let snapshot = QuotaSnapshot(planType: nil, fiveHour: quota, weekly: quota)

        view.state = .loaded(snapshot)
        XCTAssertEqual(try menu(view).item(withTitle: "展示 5 小时额度")?.state, .on)
        let weekly = try XCTUnwrap(menu(view).item(withTitle: "展示本周额度"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(weekly.action), to: weekly.target, from: weekly))

        view.provider = .gemini
        view.state = .loaded(snapshot)
        XCTAssertEqual(try menu(view).item(withTitle: "展示 5 小时额度")?.state, .on)
        view.provider = .codex
        view.state = .loaded(snapshot)
        XCTAssertEqual(try menu(view).item(withTitle: "展示本周额度")?.state, .on)
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

    func testOpenCodeMonthlyQuotaAndKeyMenu() throws {
        let view = QuotaOrbView(frame: NSRect(x: 0, y: 0, width: 111, height: 111))
        let providers = try XCTUnwrap(menu(view).item(withTitle: "切换额度来源")?.submenu)
        XCTAssertNotNil(providers.item(withTitle: "Claude Code"))
        XCTAssertNotNil(providers.item(withTitle: "OpenCode Go"))
        XCTAssertNotNil(providers.item(withTitle: "Kimi Code"))

        view.provider = .openCodeGo
        view.state = .loaded(QuotaSnapshot(
            planType: nil, fiveHour: nil, weekly: nil, monthly: QuotaWindow(usedPercent: 37, resetsAt: nil)
        ))
        let openCodeMenu = try menu(view)
        let monthly = try XCTUnwrap(openCodeMenu.item(withTitle: "展示本月额度"))
        XCTAssertTrue(monthly.isEnabled)
        XCTAssertEqual(monthly.state, .on)
        XCTAssertNotNil(openCodeMenu.item(withTitle: "设置 OpenCode Go API 密钥…"))
        XCTAssertTrue(view.toolTip?.contains("OpenCode Go 本月额度剩余 63%") == true)

        view.provider = .claudeCode
        XCTAssertNil(view.state.snapshot)
        XCTAssertNil(try menu(view).item(withTitle: "展示本月额度"))
    }

    func testMenuShowsAllReturnedWindowsAtOnce() throws {
        let view = QuotaOrbView(frame: .zero)
        view.provider = .kimiCode
        view.state = .loaded(QuotaSnapshot(
            planType: nil,
            fiveHour: QuotaWindow(usedPercent: 20, resetsAt: nil),
            weekly: QuotaWindow(usedPercent: 30, resetsAt: Date(timeIntervalSince1970: 1_800_000_000)),
            monthly: QuotaWindow(usedPercent: 40, resetsAt: nil)
        ))

        let items = try menu(view).items.map(\.title)
        XCTAssertTrue(items.contains("5 小时额度：剩余 80% · 重置时间未知"))
        XCTAssertTrue(items.contains { $0.hasPrefix("本周额度：剩余 70% · ") && $0.hasSuffix("重置") })
        XCTAssertTrue(items.contains("本月额度：剩余 60% · 重置时间未知"))
    }

    func testCopySummaryIsAvailableForSnapshotsAndIdentifiesStaleData() throws {
        let view = QuotaOrbView(frame: .zero)
        XCTAssertNil(view.quotaSummary)
        XCTAssertFalse(try XCTUnwrap(menu(view).item(withTitle: "复制额度摘要")).isEnabled)

        view.state = .stale(QuotaSnapshot(
            planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 35, resetsAt: nil)
        ), "连接中断")
        XCTAssertTrue(try XCTUnwrap(menu(view).item(withTitle: "复制额度摘要")).isEnabled)
        let summary = try XCTUnwrap(view.quotaSummary)
        XCTAssertTrue(summary.hasPrefix("Codex 额度\n本周额度：剩余 65%"))
        XCTAssertTrue(summary.contains("最后更新："))
        XCTAssertTrue(summary.hasSuffix("刷新失败（显示上次数据）"))
        XCTAssertFalse(summary.contains("连接中断"))
    }

    func testAdditionalCodexBucketsAppearOnlyWithACodexSnapshot() throws {
        let view = QuotaOrbView(frame: .zero)
        let snapshot = QuotaSnapshot(planType: nil, fiveHour: QuotaWindow(usedPercent: 20, resetsAt: nil), weekly: nil)
        view.codexMeteredQuotas = [CodexMeteredQuota(id: "extra", name: "Extra", snapshot: snapshot)]
        XCTAssertNil(try menu(view).item(withTitle: "其他 Codex 额度"))

        view.state = .loaded(snapshot)
        let extra = try XCTUnwrap(menu(view).item(withTitle: "其他 Codex 额度")?.submenu)
        XCTAssertEqual(extra.items.map(\.title), ["Extra", "5 小时额度：剩余 80% · 重置时间未知"])

        view.provider = .gemini
        view.state = .loaded(snapshot)
        XCTAssertNil(try menu(view).item(withTitle: "其他 Codex 额度"))
    }

    private func menu(_ view: QuotaOrbView) throws -> NSMenu {
        let menu = try XCTUnwrap(view.menu(for: NSEvent()))
        menu.update()
        return menu
    }
}
