import AppKit
import QuotaCore
import XCTest
@testable import PetQuotaDisplay

@MainActor
final class QuotaOrbViewTests: XCTestCase {
    func testPositionLockRemainsAccessibleAndLeavesClickRefreshAvailable() throws {
        let view = QuotaOrbView(frame: .zero)
        view.isPositionLocked = true
        let appearance = try XCTUnwrap(menu(view).item(withTitle: "外观")?.submenu)
        XCTAssertEqual(appearance.item(withTitle: "锁定悬浮球位置")?.state, .on)
        XCTAssertTrue(view.accessibilityHelp()?.contains("位置已锁定") == true)
        view.state = .failed("test")
        var refreshed = false
        view.onRefresh = { refreshed = true }
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertTrue(refreshed)
    }

    func testAccountEmailCanBeHiddenFromSelectionAndDeletionMenus() throws {
        let view = QuotaOrbView(frame: .zero)
        let account = try XCTUnwrap(CodexAccountSlot(rawValue: UUID().uuidString))
        view.accounts = [account]
        view.accountNames = [account: "Work"]
        view.accountStatuses = [account: .signedIn(CodexAccountSummary(email: "fixture@example.invalid", planType: "plus"))]
        let original = try XCTUnwrap(menu(view).item(withTitle: "切换额度账号")?.submenu)
        XCTAssertTrue(original.items.contains { $0.title.contains("fixture@example.invalid") })
        view.hidesAccountEmail = true
        let masked = try XCTUnwrap(menu(view).item(withTitle: "切换额度账号")?.submenu)
        let deletion = try XCTUnwrap(masked.item(withTitle: "删除额度账号")?.submenu)
        XCTAssertFalse((masked.items + deletion.items).contains { $0.title.contains("fixture@example.invalid") })
        XCTAssertTrue(masked.items.contains { $0.title.contains("Work · 已登录") })
    }

    func testReminderPauseExpiresAtItsEndTimeAndExposesAResumeAction() throws {
        let view = QuotaOrbView(frame: .zero)
        view.lowQuotaSoundEnabled = true
        let end = Date().addingTimeInterval(3_600)
        view.reminderPausedUntil = end
        XCTAssertTrue(view.isReminderPaused(at: end.addingTimeInterval(-1)))
        XCTAssertFalse(view.isReminderPaused(at: end))
        let reminders = try XCTUnwrap(menu(view).item(withTitle: "低额度提醒")?.submenu)
        XCTAssertNotNil(reminders.item(withTitle: "恢复低额度提醒"))
        XCTAssertNil(reminders.item(withTitle: "暂停低额度提醒 1 小时"))
    }

    func testWarningThresholdMenuUsesAnInclusiveLimit() throws {
        let view = QuotaOrbView(frame: .zero)
        let appearance = try XCTUnwrap(menu(view).item(withTitle: "外观")?.submenu)
        let levels = try XCTUnwrap(appearance.item(withTitle: "低额度警戒线")?.submenu)
        XCTAssertEqual(levels.item(withTitle: "20%")?.state, .on)
        var chosen: QuotaWarningThreshold?
        view.onSelectWarningThreshold = { chosen = $0 }
        let option = try XCTUnwrap(levels.item(withTitle: "30%"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(option.action), to: option.target, from: option))
        XCTAssertEqual(chosen, .thirtyPercent)
        XCTAssertTrue(chosen?.includes(remainingPercent: 30) == true)
        XCTAssertFalse(chosen?.includes(remainingPercent: 31) == true)
        view.warningThreshold = try XCTUnwrap(QuotaWarningThreshold(rawValue: 15))
        let customMenu = try XCTUnwrap(menu(view).item(withTitle: "外观")?.submenu?
            .item(withTitle: "低额度警戒线")?.submenu)
        XCTAssertEqual(customMenu.item(withTitle: "自定义 15%…")?.state, .on)
    }

    func testWarningPreferenceDistinguishesZeroFromAnUnsetValue() throws {
        let suite = "QuotaOrbViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(QuotaWarningThreshold.load(defaults: defaults), .twentyPercent)
        defaults.set(0, forKey: QuotaWarningThreshold.defaultsKey)
        XCTAssertEqual(QuotaWarningThreshold.load(defaults: defaults).rawValue, 0)
        defaults.set(101, forKey: QuotaWarningThreshold.defaultsKey)
        XCTAssertEqual(QuotaWarningThreshold.load(defaults: defaults), .twentyPercent)
    }

    func testLowQuotaMarkerIsAvailableToAccessibilityAndIgnoresStaleData() {
        let view = QuotaOrbView(frame: .zero)
        let snapshot = QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 80, resetsAt: nil))
        view.state = .loaded(snapshot)
        XCTAssertTrue(view.isDisplayedQuotaLow)
        XCTAssertTrue(view.accessibilityLabel()?.contains("20% 警戒线") == true)
        view.state = .stale(snapshot, "offline")
        XCTAssertFalse(view.isDisplayedQuotaLow)
        XCTAssertFalse(view.accessibilityLabel()?.contains("20% 警戒线") == true)
    }

    func testMenuBarCanIncludeTheProviderWithoutDroppingItsStatus() {
        let view = QuotaOrbView(frame: .zero)
        view.provider = .openCodeGo
        view.showsMenuBarSourceName = true
        XCTAssertEqual(view.menuBarTitle, "OpenCode Go 额度…")
        let snapshot = QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 40, resetsAt: nil))
        view.state = .stale(snapshot, "error")
        XCTAssertEqual(view.menuBarTitle, "OpenCode Go ~60%")
        view.showsMenuBarSourceName = false
        XCTAssertEqual(view.menuBarTitle, "~60%")
    }

    func testUsedPercentageChangesPresentationAndKeepsTheLowQuotaRule() throws {
        let view = QuotaOrbView(frame: .zero)
        view.provider = .gemini
        let snapshot = QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 90, resetsAt: nil))
        view.state = .loaded(snapshot)
        view.onSelectQuotaMetric = { [weak view] in view?.quotaMetric = $0 }
        let used = try XCTUnwrap(menu(view).item(withTitle: "外观")?.submenu?
            .item(withTitle: "百分比显示方式")?.submenu?.item(withTitle: "已用百分比"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(used.action), to: used.target, from: used))
        XCTAssertEqual(view.menuBarTitle, "已用 90%")
        XCTAssertTrue(view.isDisplayedQuotaLow)
        XCTAssertTrue(view.accessibilityLabel()?.contains("已用 90%，剩余 10%") == true)
        XCTAssertTrue(view.quotaSummary?.contains("剩余 10%") == true)
    }

    func testProgressRingDrawsEmptyAndFullStatesAndStartsAtTop() throws {
        let rect = NSRect(x: 10, y: 10, width: 100, height: 100)
        XCTAssertNil(QuotaOrbView.progressPath(percent: 0, in: rect))
        let full = try XCTUnwrap(QuotaOrbView.progressPath(percent: 100, in: rect)).bounds
        XCTAssertEqual(full.minX, rect.minX, accuracy: 0.001)
        XCTAssertEqual(full.minY, rect.minY, accuracy: 0.001)
        XCTAssertEqual(full.width, rect.width, accuracy: 0.001)
        XCTAssertEqual(full.height, rect.height, accuracy: 0.001)

        let quarter = try XCTUnwrap(QuotaOrbView.progressPath(percent: 25, in: rect)).bounds
        XCTAssertEqual(quarter.minX, rect.midX, accuracy: 0.001)
        XCTAssertEqual(quarter.minY, rect.minY, accuracy: 0.001)
        XCTAssertEqual(quarter.maxX, rect.maxX, accuracy: 0.001)
        XCTAssertEqual(quarter.maxY, rect.midY, accuracy: 0.001)
    }

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
        let appearance = try XCTUnwrap(menu(view).item(withTitle: "外观")?.submenu)
        let sizes = try XCTUnwrap(appearance.item(withTitle: "悬浮球大小")?.submenu)
        XCTAssertEqual(sizes.items.map(\.title), ["小", "标准", "大"])
        XCTAssertEqual(sizes.item(withTitle: "标准")?.state, .on)

        let large = try XCTUnwrap(sizes.item(withTitle: "大"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(large.action), to: large.target, from: large))
        XCTAssertEqual(view.sizePreference, .large)
        let updated = try XCTUnwrap(menu(view).item(withTitle: "外观")?.submenu)
        XCTAssertEqual(updated.item(withTitle: "悬浮球大小")?.submenu?.item(withTitle: "大")?.state, .on)
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

    func testAdaptivePeriodTracksTheSmallestRemainingQuota() throws {
        let suite = "QuotaOrbViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let view = QuotaOrbView(frame: .zero, defaults: defaults)
        view.provider = .openCodeGo
        let automatic = try XCTUnwrap(menu(view).item(withTitle: "自动展示剩余最少的周期"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(automatic.action), to: automatic.target, from: automatic))

        let fiveHour = QuotaWindow(usedPercent: 50, resetsAt: nil)
        let monthly = QuotaWindow(usedPercent: 60, resetsAt: nil)
        view.state = .loaded(QuotaSnapshot(planType: nil, fiveHour: fiveHour, weekly: nil, monthly: monthly))
        XCTAssertEqual(view.menuBarTitle, "40%")
        XCTAssertEqual(try menu(view).item(withTitle: "展示本月额度")?.state, .mixed)

        view.state = .loaded(QuotaSnapshot(planType: nil, fiveHour: fiveHour, weekly: QuotaWindow(usedPercent: 95, resetsAt: nil), monthly: monthly))
        XCTAssertEqual(view.menuBarTitle, "5%")
        XCTAssertEqual(try menu(view).item(withTitle: "自动展示剩余最少的周期")?.state, .on)
    }

    func testCodexAccountsRememberSeparatePeriods() throws {
        let suite = "QuotaOrbViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("weekly", forKey: QuotaWindowPreference.key(for: .codex))
        let view = QuotaOrbView(frame: .zero, defaults: defaults)
        let first = try XCTUnwrap(CodexAccountSlot(rawValue: UUID().uuidString))
        let second = try XCTUnwrap(CodexAccountSlot(rawValue: UUID().uuidString))
        let quota = QuotaWindow(usedPercent: 10, resetsAt: nil)
        view.selectedAccount = first
        view.state = .loaded(QuotaSnapshot(planType: nil, fiveHour: quota, weekly: quota))
        let fiveHour = try XCTUnwrap(menu(view).item(withTitle: "展示 5 小时额度"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(fiveHour.action), to: fiveHour.target, from: fiveHour))

        view.selectedAccount = second
        XCTAssertEqual(try menu(view).item(withTitle: "展示本周额度")?.state, .on)
        view.selectedAccount = first
        XCTAssertEqual(try menu(view).item(withTitle: "展示 5 小时额度")?.state, .on)
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

    func testRecentQuotasSurviveSwitchingProvidersAndKeepCodexAccountsSeparate() throws {
        let view = QuotaOrbView(frame: .zero)
        XCTAssertNil(view.recentQuotaSummary)
        let account = try XCTUnwrap(CodexAccountSlot(rawValue: UUID().uuidString))
        view.selectedAccount = account
        view.state = .loaded(QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 10, resetsAt: nil)))
        view.provider = .gemini
        view.state = .loaded(QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 35, resetsAt: nil)))

        let entries = try XCTUnwrap(menu(view).item(withTitle: "最近读取的额度")?.submenu)
        XCTAssertTrue(try XCTUnwrap(entries.item(withTitle: "复制最近额度总览")).isEnabled)
        XCTAssertTrue(entries.item(withTitle: "Codex")?.submenu?.items.contains { $0.title.contains("90%") } == true)
        XCTAssertTrue(entries.item(withTitle: "Gemini")?.submenu?.items.contains { $0.title.contains("65%") } == true)
        XCTAssertNotNil(entries.item(withTitle: "Kimi Code · 尚无结果"))
        let summary = try XCTUnwrap(view.recentQuotaSummary)
        XCTAssertTrue(summary.contains("Codex\n本周额度：剩余 90%"))
        XCTAssertTrue(summary.contains("Gemini\n本周额度：剩余 65%"))
        XCTAssertFalse(summary.contains(account.rawValue))

        view.selectedAccount = try XCTUnwrap(CodexAccountSlot(rawValue: UUID().uuidString))
        let switched = try XCTUnwrap(menu(view).item(withTitle: "最近读取的额度")?.submenu)
        XCTAssertNotNil(switched.item(withTitle: "Codex · 尚无结果"))
        XCTAssertFalse(try XCTUnwrap(view.recentQuotaSummary).contains("Codex"))

        view.selectedAccount = account
        view.forgetQuota(for: .codex, account: account)
        let cleared = try XCTUnwrap(menu(view).item(withTitle: "最近读取的额度")?.submenu)
        XCTAssertNotNil(cleared.item(withTitle: "Codex · 尚无结果"))
    }

    func testReturningToAProviderShowsItsPreviousResultWhileRefreshing() throws {
        let view = QuotaOrbView(frame: .zero)
        let snapshot = QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 32, resetsAt: nil))
        view.provider = .gemini
        view.state = .loaded(snapshot)

        view.provider = .kimiCode
        view.beginPollingWithRecentQuota()
        XCTAssertEqual(view.state, .loading)
        view.provider = .gemini
        view.beginPollingWithRecentQuota()
        XCTAssertEqual(view.state, .refreshing(snapshot))
        XCTAssertEqual(view.menuBarTitle, "68%…")
        XCTAssertNotNil(try menu(view).item(withTitle: "正在刷新，显示上次数据"))
    }

    func testClearingRecentQuotaLeavesTheCurrentDisplayIntact() throws {
        let view = QuotaOrbView(frame: .zero)
        view.provider = .gemini
        view.state = .loaded(QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 30, resetsAt: nil)))
        let recent = try XCTUnwrap(menu(view).item(withTitle: "最近读取的额度")?.submenu)
        let clear = try XCTUnwrap(recent.item(withTitle: "清空最近额度记录"))
        XCTAssertTrue(clear.isEnabled)
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(clear.action), to: clear.target, from: clear))
        XCTAssertNil(view.recentQuotaSummary)
        XCTAssertEqual(view.menuBarTitle, "70%")
        let updated = try XCTUnwrap(menu(view).item(withTitle: "最近读取的额度")?.submenu)
        XCTAssertFalse(try XCTUnwrap(updated.item(withTitle: "清空最近额度记录")).isEnabled)
    }

    func testClearingOneProviderLeavesOtherHistoryAndTheCurrentQuota() throws {
        let view = QuotaOrbView(frame: .zero)
        let snapshot = QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 45, resetsAt: nil))
        view.provider = .kimiCode
        view.state = .loaded(snapshot)
        view.provider = .gemini
        view.state = .loaded(snapshot)

        let clear = try XCTUnwrap(menu(view).item(withTitle: "最近读取的额度")?.submenu?
            .item(withTitle: "Gemini")?.submenu?.item(withTitle: "清除此来源的记录"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(clear.action), to: clear.target, from: clear))
        XCTAssertEqual(view.state.snapshot, snapshot)
        XCTAssertTrue(view.recentQuotaSummary?.contains("Kimi Code") == true)
        XCTAssertFalse(view.recentQuotaSummary?.contains("Gemini") == true)
    }

    func testRecentMenuShowsEightReadingsWithTheNewestFirst() throws {
        let view = QuotaOrbView(frame: .zero)
        view.provider = .gemini
        for offset in 1...10 {
            let window = QuotaWindow(usedPercent: offset, resetsAt: nil)
            view.state = .loaded(QuotaSnapshot(planType: nil, fiveHour: nil, weekly: window,
                                               fetchedAt: Date(timeIntervalSince1970: TimeInterval(offset))))
        }

        let details = try XCTUnwrap(menu(view).item(withTitle: "最近读取的额度")?.submenu?
            .item(withTitle: "Gemini")?.submenu)
        let list = try XCTUnwrap(details.item(withTitle: "最近采集记录")?.submenu)
        XCTAssertEqual(list.items.count, 8)
        XCTAssertTrue(list.items.first?.title.hasSuffix("本周 90%") == true)
        XCTAssertTrue(list.items.last?.title.hasSuffix("本周 97%") == true)

        var selectedProvider: QuotaProvider?
        var readings: [QuotaSnapshot] = []
        view.onShowQuotaHistory = { context, history in
            selectedProvider = context.provider
            readings = history
        }
        let trend = try XCTUnwrap(details.item(withTitle: "查看额度趋势…"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(trend.action), to: trend.target, from: trend))
        XCTAssertEqual(selectedProvider, .gemini)
        XCTAssertEqual(readings.count, 10)
        XCTAssertEqual(readings.last?.weekly?.remainingPercent, 90)
        let json = try XCTUnwrap(view.quotaHistoryJSON(for: .gemini))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(report["schemaVersion"] as? Int, 1)
        XCTAssertEqual(report["provider"] as? String, "gemini")
        let exported = try XCTUnwrap(report["readings"] as? [[String: Any]])
        XCTAssertEqual(exported.count, 10)
        XCTAssertNil(report["account"])
    }

    func testHistoryChangeEventsRetainTheAccountScopeAndIgnoreDuplicateReads() throws {
        let view = QuotaOrbView(frame: .zero)
        view.provider = .codex
        let account = try XCTUnwrap(CodexAccountSlot(rawValue: UUID().uuidString))
        view.selectedAccount = account
        var changes: [(QuotaHistoryContext, Int)] = []
        view.onQuotaHistoryChanged = { batch in
            changes.append(contentsOf: batch.map { ($0.key, $0.value.count) })
        }
        let snapshot = QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 5, resetsAt: nil))
        view.state = .loaded(snapshot)
        view.state = .loaded(snapshot)
        view.forgetQuota(for: .codex, account: account)
        XCTAssertEqual(changes.map { $0.0.account }, [account, account])
        XCTAssertEqual(changes.map { $0.1 }, [1, 0])
    }

    func testModelHistoryMenuUsesIndependentReadingsForTheSelectedAccount() throws {
        let view = QuotaOrbView(frame: .zero)
        let account = try XCTUnwrap(CodexAccountSlot(rawValue: UUID().uuidString))
        view.selectedAccount = account
        let primary = QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 20, resetsAt: nil))
        let additional = QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 90, resetsAt: nil))
        view.codexMeteredQuotas = [CodexMeteredQuota(id: "extra", name: "Extra", snapshot: additional)]
        var batches: [[QuotaHistoryContext: [QuotaSnapshot]]] = []
        view.onQuotaHistoryChanged = { batches.append($0) }
        view.state = .loaded(primary)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.count, 2)
        view.state = .loaded(primary)
        XCTAssertEqual(batches.count, 1)
        let models = try XCTUnwrap(menu(view).item(withTitle: "最近读取的额度")?.submenu?
            .item(withTitle: "Codex")?.submenu?.item(withTitle: "独立模型")?.submenu)
        let trend = try XCTUnwrap(models.item(withTitle: "extra")?.submenu?.item(withTitle: "查看额度趋势…"))
        var opened: QuotaHistoryContext?
        view.onShowQuotaHistory = { context, readings in
            opened = context
            XCTAssertEqual(readings, [additional])
        }
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(trend.action), to: trend.target, from: trend))
        XCTAssertEqual(opened, QuotaHistoryContext(provider: .codex, account: account, modelID: "extra"))
        let export = try XCTUnwrap(view.allQuotaHistoryJSON)
        XCTAssertTrue(export.contains("extra"))
        XCTAssertFalse(export.contains(account.rawValue))
        view.selectedAccount = try XCTUnwrap(CodexAccountSlot(rawValue: UUID().uuidString))
        XCTAssertNil(view.quotaHistoryJSON(for: .codex, modelID: "extra"))
        XCTAssertNil(view.allQuotaHistoryJSON)
        view.selectedAccount = account
        let clear = try XCTUnwrap(models.item(withTitle: "extra")?.submenu?.item(withTitle: "清除此模型的记录"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(clear.action), to: clear.target, from: clear))
        XCTAssertNil(view.quotaHistoryJSON(for: .codex, modelID: "extra"))
        XCTAssertEqual(view.historyForArchive[QuotaHistoryContext(provider: .codex, account: account)], [primary])
        view.forgetQuota(for: .codex, account: account)
        XCTAssertTrue(view.historyForArchive.isEmpty)
    }

    func testCurrentTrendShortcutOpensTheDisplayedModel() throws {
        let suite = "QuotaOrbViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let view = QuotaOrbView(frame: .zero, defaults: defaults)
        let account = try XCTUnwrap(CodexAccountSlot(rawValue: UUID().uuidString))
        view.selectedAccount = account
        let primary = QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 20, resetsAt: nil))
        let extra = QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 90, resetsAt: nil))
        view.codexMeteredQuotas = [CodexMeteredQuota(id: "extra", name: "Extra", snapshot: extra)]
        view.state = .loaded(primary)
        let selection = try XCTUnwrap(menu(view).item(withTitle: "选择 Codex 额度")?.submenu?.item(withTitle: "Extra"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(selection.action), to: selection.target, from: selection))
        var opened: QuotaHistoryContext?
        view.onShowQuotaHistory = { context, _ in opened = context }
        let shortcut = try XCTUnwrap(menu(view).item(withTitle: "查看当前额度趋势…"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(shortcut.action), to: shortcut.target, from: shortcut))
        XCTAssertEqual(opened?.modelID, "extra")
    }

    func testModelTrendHasAGapWhenASuccessfulCodexRefreshOmitsTheModel() throws {
        let view = QuotaOrbView(frame: .zero)
        let account = try XCTUnwrap(CodexAccountSlot(rawValue: UUID().uuidString))
        view.selectedAccount = account
        let scope = QuotaHistoryContext(provider: .codex, account: account, modelID: "extra")
        for offset in 1...3 {
            let reading = QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 20, resetsAt: nil),
                                        fetchedAt: Date(timeIntervalSince1970: TimeInterval(offset)))
            view.codexMeteredQuotas = offset == 2 ? [] : [CodexMeteredQuota(id: "extra", name: "Extra", snapshot: reading)]
            view.state = .loaded(reading)
        }
        XCTAssertEqual(view.historyForArchive[scope]?.count, 2)
        let readings = view.trendReadings(for: scope)
        XCTAssertEqual(readings.count, 3)
        XCTAssertEqual(QuotaHistorySeries(readings: readings, period: .weekly).points.map(\.segment), [0, 1])
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

    func testJSONExportIncludesPeriodsAndStaleStateWithoutRawErrors() throws {
        let view = QuotaOrbView(frame: .zero)
        view.provider = .gemini
        XCTAssertNil(view.quotaJSON)
        view.state = .stale(QuotaSnapshot(
            planType: nil,
            fiveHour: nil,
            weekly: QuotaWindow(usedPercent: 15, resetsAt: Date(timeIntervalSince1970: 200)),
            fetchedAt: Date(timeIntervalSince1970: 100)
        ), "fixture error details")

        let json = try XCTUnwrap(view.quotaJSON)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertFalse(json.contains("fixture error details"))
        XCTAssertEqual(payload["provider"] as? String, "gemini")
        XCTAssertEqual(payload["status"] as? String, "stale")
        XCTAssertEqual(payload["fetchedAt"] as? String, "1970-01-01T00:01:40Z")
        let periods = try XCTUnwrap(payload["periods"] as? [[String: Any]])
        XCTAssertEqual(periods.count, 1)
        XCTAssertEqual(periods.first?["id"] as? String, "weekly")
        XCTAssertEqual(periods.first?["remainingPercent"] as? Int, 85)
        XCTAssertEqual(periods.first?["resetsAt"] as? String, "1970-01-01T00:03:20Z")
    }

    func testAdditionalCodexBucketsAppearOnlyWithACodexSnapshot() throws {
        let view = QuotaOrbView(frame: .zero)
        let snapshot = QuotaSnapshot(planType: nil, fiveHour: QuotaWindow(usedPercent: 20, resetsAt: nil), weekly: nil)
        view.codexMeteredQuotas = [CodexMeteredQuota(id: "extra", name: "Extra", snapshot: snapshot)]
        XCTAssertNil(try menu(view).item(withTitle: "选择 Codex 额度"))

        view.state = .loaded(snapshot)
        let extra = try XCTUnwrap(menu(view).item(withTitle: "选择 Codex 额度")?.submenu)
        XCTAssertEqual(extra.items.filter { !$0.isSeparatorItem }.map(\.title), ["主要额度", "Extra", "5 小时额度：剩余 80% · 重置时间未知"])

        view.provider = .gemini
        view.state = .loaded(snapshot)
        XCTAssertNil(try menu(view).item(withTitle: "选择 Codex 额度"))
    }

    func testSelectedCodexBucketUpdatesDisplayAndFallsBackWhenUnavailable() throws {
        let suite = "QuotaOrbViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let primary = QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 20, resetsAt: nil))
        let extra = QuotaSnapshot(planType: nil, fiveHour: QuotaWindow(usedPercent: 70, resetsAt: nil), weekly: nil)
        let selection = CodexMeteredQuota(id: "extra", name: "Extra", snapshot: extra)
        let view = QuotaOrbView(frame: .zero, defaults: defaults)
        view.selectedAccount = try XCTUnwrap(CodexAccountSlot(rawValue: UUID().uuidString))
        view.codexMeteredQuotas = [selection]
        view.state = .loaded(primary)

        let bucket = try XCTUnwrap(menu(view).item(withTitle: "选择 Codex 额度")?.submenu?.item(withTitle: "Extra"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(bucket.action), to: bucket.target, from: bucket))
        XCTAssertEqual(view.menuBarTitle, "30%")
        XCTAssertTrue(view.quotaSummary?.contains("Codex · Extra") == true)
        XCTAssertEqual(try menu(view).item(withTitle: "展示 5 小时额度")?.state, .on)

        view.codexMeteredQuotas = []
        view.state = .loaded(primary)
        XCTAssertEqual(view.menuBarTitle, "80%")
        view.codexMeteredQuotas = [selection]
        view.state = .loaded(primary)
        XCTAssertEqual(view.menuBarTitle, "30%")
    }

    private func menu(_ view: QuotaOrbView) throws -> NSMenu {
        let menu = try XCTUnwrap(view.menu(for: NSEvent()))
        menu.update()
        return menu
    }
}
