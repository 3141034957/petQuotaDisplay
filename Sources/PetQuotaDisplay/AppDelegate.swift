import AppKit
import QuotaCore
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private static let codexBundleIdentifier = "com.openai.codex"
    private static let quotaMenuBarImage = NSImage(systemSymbolName: "gauge", accessibilityDescription: nil)
    private static let lowQuotaMenuBarImage = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)

    private var orbSizePreference = OrbSizePreference.load()
    private var orbSize: NSSize { orbSizePreference.size }
    private let displayOptions: QuotaDisplayOptions
    private var monitorsCodexDesktop: Bool { displayOptions.mode?.monitorsCodexDesktop == true }
    private var monitorsCodexCLI: Bool { displayOptions.mode?.monitorsCodexCLI == true }
    private var followCodex: Bool { monitorsCodexDesktop || monitorsCodexCLI }
    private var forceOrbVisible: Bool { displayOptions.mode == .forceOrb }
    private var workspaceOnly: Bool { displayOptions.opensWorkspace && displayOptions.mode == nil }
    private var client: CodexQuotaClient?
    private var pollingClient: PollingQuotaClient?
    private var window: NSWindow!
    private var orbView: QuotaOrbView!
    private var refreshTimer: Timer?
    private let claudeCacheMonitor = ClaudeQuotaCacheMonitor(directory: ClaudeQuotaCache.directory)
    private var historyWindows: [QuotaHistoryContext: (controller: NSWindowController, model: QuotaHistoryWindowModel)] = [:]
    private var workspaceController: NSWindowController?
    private var workspaceModel: WorkspaceDashboardModel?
    private var nextHistoryWindowLocation = NSPoint.zero
    private let historyArchive = QuotaHistoryArchive.local
    private let historyArchiveWriter = DispatchQueue(label: "com.erenshwang.petquotadisplay.history", qos: .utility)
    private var historyArchiveGeneration = UUID()
    private var lowQuotaReminder = QuotaLowReminder()
    private lazy var quotaNotifications: QuotaNotificationService = {
        let service = QuotaNotificationService()
        service.onShowHistory = { [weak self] context in self?.showHistoryFromNotification(context) }
        return service
    }()
    private var isRequestingNotifications = false
    private var countdownTimer: Timer?
    private var statusItem: NSStatusItem?
    private var orbIsActive = false
    private var cliMonitor: CodexCLIProcessMonitor?
    private var codexGUIRunning = false
    private var codexCLIRunning = false
    private var accounts: [CodexAccountSlot]
    private var selectedAccount: CodexAccountSlot?
    private var accountStatuses: [CodexAccountSlot: CodexAccountStatus] = [:]
    private var pendingAccountLogin: CodexAccountSlot?
    private var pendingLoginReplacesExisting = false
    private var suppressOrbUntilCodexStops = false

    init(displayOptions: QuotaDisplayOptions) {
        self.displayOptions = displayOptions
        let accounts = CodexAccountProfile.loadAccounts()
        self.accounts = accounts
        self.selectedAccount = CodexAccountProfile.selectedAccount(in: accounts)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(workspaceOnly ? .regular : .accessory)
        if workspaceOnly {
            let mainMenu = NSMenu()
            let appItem = NSMenuItem()
            let appMenu = NSMenu(title: "PetQuota")
            appMenu.addItem(withTitle: "退出 PetQuota", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            appItem.submenu = appMenu
            mainMenu.addItem(appItem)
            let editItem = NSMenuItem()
            let editMenu = NSMenu(title: "编辑")
            editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
            editMenu.addItem(.separator())
            editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            editItem.submenu = editMenu
            mainMenu.addItem(editItem)
            NSApp.mainMenu = mainMenu
        }
        for account in accounts where CodexAccountProfile.hasStoredCredentials(for: account) {
            accountStatuses[account] = .stored
        }
        createWindow()
        restoreHistoryArchive()
        checkNotificationAuthorization()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemTimeZoneDidChange(_:)),
            name: .NSSystemTimeZoneDidChange,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )

        if monitorsCodexDesktop {
            let notifications = NSWorkspace.shared.notificationCenter
            notifications.addObserver(
                self,
                selector: #selector(workspaceApplicationDidLaunch(_:)),
                name: NSWorkspace.didLaunchApplicationNotification,
                object: nil
            )
            notifications.addObserver(
                self,
                selector: #selector(workspaceApplicationDidTerminate(_:)),
                name: NSWorkspace.didTerminateApplicationNotification,
                object: nil
            )
            codexGUIRunning = isCodexRunning()
        }
        if monitorsCodexCLI {
            let cliMonitor = CodexCLIProcessMonitor()
            cliMonitor.onRunningStateChanged = { [weak self] isRunning in
                self?.codexCLIRunning = isRunning
                self?.reconcileOrbVisibility()
            }
            self.cliMonitor = cliMonitor
            cliMonitor.start()
        }
        if displayOptions.opensWorkspace { showWorkspace() }
        guard !workspaceOnly else { return }
        if followCodex {
            reconcileOrbVisibility()
        } else {
            startOrb()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspaceModel?.shutdown()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        cliMonitor?.stop()
        cliMonitor = nil
        stopOrb(hideWindow: false)
        historyArchiveWriter.sync {}
        QuotaChildProcess.waitForTerminations()
        removeStatusItem()
    }

    private func createWindow() {
        window = NSWindow(
            contentRect: NSRect(origin: restoredOrDefaultOrigin(), size: orbSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        let staysOnTop = QuotaPreferences.orbStaysOnTop()
        window.level = staysOnTop ? .floating : .normal
        window.isReleasedWhenClosed = false
        window.animationBehavior = .utilityWindow

        orbView = QuotaOrbView(frame: NSRect(origin: .zero, size: orbSize))
        orbView.autoresizingMask = [.width, .height]
        orbView.provider = displayOptions.provider ?? QuotaPreferences.selectedProvider()
        orbView.startupPeriodOverride = displayOptions.period
        orbView.refreshCadence = displayOptions.refreshCadence ?? QuotaRefreshCadence.load()
        orbView.historyRetention = QuotaHistoryRetention.load()
        orbView.showsMenuBarQuota = QuotaPreferences.shared.bool(forKey: QuotaPreferences.menuBarEnabledKey)
        orbView.hidesAccountEmail = QuotaPreferences.shared.bool(forKey: QuotaPreferences.hidesAccountEmailKey)
        orbView.isPositionLocked = QuotaPreferences.shared.bool(forKey: QuotaPreferences.orbPositionLockedKey)
        orbView.showsMenuBarSourceName = QuotaPreferences.shared.bool(forKey: QuotaPreferences.menuBarSourceNameKey)
        orbView.warningThreshold = QuotaWarningThreshold.load()
        orbView.lowQuotaSoundEnabled = QuotaPreferences.shared.bool(forKey: QuotaPreferences.lowQuotaSoundKey)
        orbView.reminderPeriods = QuotaPreferences.reminderPeriods()
        orbView.reminderPausedUntil = QuotaPreferences.shared.object(forKey: QuotaPreferences.lowQuotaPauseUntilKey) as? Date
        orbView.supportsLowQuotaNotifications = QuotaNotificationService.isSupported
        orbView.lowQuotaNotificationEnabled = orbView.supportsLowQuotaNotifications
            && QuotaPreferences.shared.bool(forKey: QuotaPreferences.lowQuotaNotificationKey)
        orbView.menuBarOnly = !forceOrbVisible && orbView.showsMenuBarQuota
            && QuotaPreferences.shared.bool(forKey: QuotaPreferences.menuBarOnlyKey)
        orbView.sizePreference = orbSizePreference
        orbView.opacityPreference = OrbOpacityPreference.load()
        applyOrbDisplayOptions()
        orbView.quotaMetric = QuotaPreferences.shared.string(forKey: OrbQuotaMetric.defaultsKey)
            .flatMap(OrbQuotaMetric.init(rawValue:)) ?? .remaining
        orbView.staysOnTop = staysOnTop
        orbView.showsOnAllSpaces = QuotaPreferences.shared.object(forKey: QuotaPreferences.orbAllSpacesKey) as? Bool ?? true
        applyOrbSpacePreference()
        let savedResetDisplay = QuotaPreferences.shared.string(forKey: OrbResetDisplay.defaultsKey)
        orbView.resetDisplay = savedResetDisplay.flatMap(OrbResetDisplay.init(rawValue:)) ?? .time
        orbView.onSelectProvider = { [weak self] provider in self?.switchProvider(to: provider) }
        orbView.onSelectRefreshCadence = { [weak self] cadence in self?.setRefreshCadence(cadence) }
        claudeCacheMonitor.onChange = { [weak self] in self?.refreshDisplayedQuota() }
        orbView.onRefresh = { [weak self] in
            guard let self else { return }
            if self.client != nil { self.orbView.state.beginRefresh() }
            self.refreshDisplayedQuota()
        }
        orbView.onQuit = { [weak self] in self?.quitOrHideOrb() }
        orbView.onShowAbout = { [weak self] in self?.showAbout() }
        orbView.onShowWorkspace = { [weak self] in self?.showWorkspace() }
        orbView.onPositionChanged = { [weak self] in self?.finishOrbDrag() }
        orbView.onResetPosition = { [weak self] in self?.resetOrbPosition() }
        orbView.onSelectCorner = { [weak self] corner in self?.moveOrb(to: corner) }
        orbView.displayChoices = { [weak self] in self?.orbDisplayChoices() ?? [] }
        orbView.onSelectDisplay = { [weak self] displayID in self?.moveOrb(toDisplay: displayID) }
        orbView.onTogglePositionLock = { [weak self] in self?.togglePositionLock() }
        orbView.onSelectSize = { [weak self] size in self?.resizeOrb(to: size) }
        orbView.onSelectOpacity = { [weak self] opacity in self?.setOrbOpacity(opacity) }
        orbView.onSelectQuotaMetric = { [weak self] metric in
            self?.orbView.quotaMetric = metric
            QuotaPreferences.shared.set(metric.rawValue, forKey: OrbQuotaMetric.defaultsKey)
        }
        orbView.onSelectResetDisplay = { [weak self] mode in self?.setResetDisplay(mode) }
        orbView.onToggleMenuBarQuota = { [weak self] in self?.toggleMenuBarQuota() }
        orbView.onToggleMenuBarSourceName = { [weak self] in self?.toggleMenuBarSourceName() }
        orbView.onToggleAccountEmail = { [weak self] in self?.toggleAccountEmail() }
        orbView.onSelectWarningThreshold = { [weak self] threshold in self?.setWarningThreshold(threshold) }
        orbView.onEditWarningThreshold = { [weak self] in self?.editWarningThreshold() }
        orbView.onToggleLowQuotaSound = { [weak self] in self?.toggleLowQuotaSound() }
        orbView.onToggleLowQuotaNotifications = { [weak self] in self?.toggleLowQuotaNotifications() }
        orbView.onToggleReminderPeriod = { [weak self] period in self?.toggleReminderPeriod(period) }
        orbView.onToggleReminderPause = { [weak self] in self?.toggleReminderPause() }
        orbView.onFreshQuota = { [weak self] scope, snapshot in self?.handleLowQuota(scope, snapshot: snapshot) }
        orbView.onToggleWindowLevel = { [weak self] in self?.toggleWindowLevel() }
        orbView.onToggleSpaces = { [weak self] in self?.toggleOrbSpaces() }
        orbView.onRaiseOrb = { [weak self] in self?.reconcileWindowVisibility() }
        orbView.onToggleOrbVisibility = { [weak self] in
            guard let self, self.orbView.showsMenuBarQuota else { return }
            self.setMenuBarOnly(!self.orbView.menuBarOnly)
        }
        orbView.onPresentationChanged = { [weak self] in self?.updateStatusItem() }
        orbView.onShowQuotaHistory = { [weak self] context, readings in self?.showQuotaHistory(context: context, readings: readings) }
        orbView.onQuotaHistoryChanged = { [weak self] changes in self?.historyDidChange(changes) }
        orbView.onQuotaHistoryScopeCleared = { [weak self] scope, removed in self?.historyScopeCleared(scope, removed: removed) }
        orbView.onQuotaHistoryCleared = { [weak self] in self?.clearHistory() }
        orbView.onSaveQuotaHistory = { [weak self] contents, format in self?.saveHistory(contents, format: format) }
        orbView.onImportQuotaHistory = { [weak self] in self?.importHistory() }
        orbView.onToggleHistoryArchive = { [weak self] in self?.toggleHistoryArchive() }
        orbView.onRevealHistoryArchive = { [weak self] in self?.revealHistoryArchive() }
        orbView.onSelectHistoryRetention = { [weak self] retention in self?.setHistoryRetention(retention) }
        orbView.onResetHistoryArchive = { [weak self] in self?.resetHistoryArchive() }
        orbView.onSelectAccount = { [weak self] account in self?.switchAccount(to: account) }
        orbView.onAddAccount = { [weak self] in self?.addAccount() }
        orbView.onLoginAccount = { [weak self] account in self?.loginAccount(account) }
        orbView.onCancelLogin = { [weak self] in self?.client?.cancelChatGPTLogin() }
        orbView.onRenameAccount = { [weak self] account in self?.renameAccount(account) }
        orbView.onDeleteAccount = { [weak self] account in self?.deleteAccount(account) }
        orbView.onConfigureOpenCodeGo = { [weak self] in self?.configureOpenCodeGo() }
        orbView.quitMenuTitle = followCodex ? "本次隐藏额度显示" : "退出额度悬浮球"
        updateAccountMenuState()
        window.contentView = orbView
    }

    private func startOrb() {
        guard !orbIsActive else { return }
        orbIsActive = true
        reconcileWindowVisibility()
        reconcileStatusItem()

        switch orbView.provider {
        case .codex: startCodexClient()
        case .gemini: startPollingClient(GeminiQuotaClient())
        case .claudeCode: refreshClaudeQuota()
        case .openCodeGo: startPollingClient(OpenCodeGoQuotaClient())
        case .kimiCode: startPollingClient(KimiQuotaClient())
        }
        scheduleRefreshTimer()
        scheduleCountdownTimer()
    }

    private func showQuotaHistory(context: QuotaHistoryContext, readings: [QuotaSnapshot]) {
        if let existing = historyWindows[context] {
            existing.model.readings = readings
            NSApp.activate(ignoringOtherApps: true)
            existing.controller.showWindow(nil)
            existing.controller.window?.makeKeyAndOrderFront(nil)
            return
        }
        let model = QuotaHistoryWindowModel(context: context, readings: readings, warningThreshold: orbView.warningThreshold)
        let content = NSHostingController(rootView: QuotaHistoryView(model: model))
        let historyWindow = NSWindow(contentViewController: content)
        historyWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        historyWindow.isReleasedWhenClosed = false
        historyWindow.setContentSize(NSSize(width: 540, height: 360))
        historyWindow.delegate = self
        if historyWindows.isEmpty {
            historyWindow.center()
            nextHistoryWindowLocation = NSPoint(x: historyWindow.frame.minX + 24, y: historyWindow.frame.maxY - 24)
        } else {
            nextHistoryWindowLocation = historyWindow.cascadeTopLeft(from: nextHistoryWindowLocation)
        }
        historyWindow.title = historyWindowTitle(for: context)
        let controller = NSWindowController(window: historyWindow)
        historyWindows[context] = (controller, model)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if workspaceOnly { showWorkspace() }
        return true
    }

    private func showWorkspace() {
        if let workspaceController {
            workspaceModel?.reload()
            NSApp.activate(ignoringOtherApps: true)
            workspaceController.window?.makeKeyAndOrderFront(nil)
            return
        }
        let model = WorkspaceDashboardModel()
        model.getSelectedCodex = { [weak self] in self?.selectedAccount }
        model.selectCodex = { [weak self] account in self?.selectWorkspaceCodex(account) }
        model.startCodexLogin = { [weak self] account in
            guard let self else { return }
            if self.orbView.provider != .codex { self.switchProvider(to: .codex) }
            if let account { self.loginAccount(account) }
            else { self.addAccount() }
        }
        model.removeCodex = { [weak self] account in self?.deleteAccount(account) }
        model.refreshActiveCodex = { [weak self] slot in
            guard let self, let client = self.client, self.selectedAccount == slot else { return false }
            client.refresh()
            return true
        }
        let hosting = NSHostingController(rootView: WorkspaceDashboardView(model: model))
        let workspaceWindow = NSWindow(contentViewController: hosting)
        workspaceWindow.title = "PetQuota 工作台"
        workspaceWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        workspaceWindow.isReleasedWhenClosed = false
        workspaceWindow.contentMinSize = NSSize(width: 840, height: 540)
        workspaceWindow.setContentSize(NSSize(width: 1_000, height: 670))
        workspaceWindow.setFrameAutosaveName("PetQuotaWorkspace")
        if !workspaceWindow.setFrameUsingName("PetQuotaWorkspace") { workspaceWindow.center() }
        let controller = NSWindowController(window: workspaceWindow)
        workspaceModel = model
        workspaceController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        workspaceWindow.makeKeyAndOrderFront(nil)
    }

    private func selectWorkspaceCodex(_ account: CodexAccountSlot) {
        accounts = CodexAccountProfile.loadAccounts()
        guard accounts.contains(account) else { return }
        if accountStatuses[account] == nil, CodexAccountProfile.hasStoredCredentials(for: account) {
            accountStatuses[account] = .stored
        }
        let wasActive = orbIsActive
        if wasActive { stopOrb(hideWindow: false) }
        selectedAccount = account
        orbView.provider = .codex
        orbView.startupPeriodOverride = nil
        QuotaPreferences.shared.set(account.rawValue, forKey: CodexAccountProfile.selectedAccountDefaultsKey)
        QuotaPreferences.shared.set(QuotaProvider.codex.rawValue, forKey: QuotaPreferences.selectedProviderKey)
        updateAccountMenuState()
        if wasActive { startOrb() }
    }

    private func historyWindowTitle(for context: QuotaHistoryContext) -> String {
        let parts = [context.provider.title, context.account.map(accountName(for:)), context.modelID, "额度趋势"].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    private func updateHistoryWindowTitles() {
        for (context, openWindow) in historyWindows {
            openWindow.controller.window?.title = historyWindowTitle(for: context)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let context = historyWindows.first(where: { $0.value.controller.window === window })?.key else { return }
        historyWindows.removeValue(forKey: context)
    }

    private func showHistoryFromNotification(_ context: QuotaHistoryContext) {
        let readings = orbView.trendReadings(for: context)
        if !readings.isEmpty {
            showQuotaHistory(context: context, readings: readings)
        } else {
            let alert = NSAlert()
            alert.messageText = "暂无此通知对应的采集记录"
            alert.addButton(withTitle: "关闭")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func updateQuotaHistory(after changes: [QuotaHistoryContext: [QuotaSnapshot]]) {
        let affected = historyWindows.filter { context, _ in changes[context] != nil || changes[context.primary] != nil }
        for (context, openWindow) in affected {
            let readings = orbView.trendReadings(for: context)
            if readings.isEmpty {
                historyWindows.removeValue(forKey: context)
                openWindow.controller.close()
            } else {
                openWindow.model.readings = readings
            }
        }
    }

    private func restoreHistoryArchive() {
        performHistoryArchiveOperation {
            let state = try historyArchive.load()
            orbView.retainsHistoryAcrossLaunches = state.isEnabled
            orbView.restoreHistory(state.histories.filter { context, _ in
                context.provider != .codex || context.account.map(accounts.contains) == true
            })
        }
    }

    private func toggleHistoryArchive() {
        performHistoryArchiveOperation {
            let enabled = !orbView.retainsHistoryAcrossLaunches
            let initial = orbView.historyForArchive
            try historyArchiveWriter.sync { try historyArchive.setEnabled(enabled, initial: initial) }
            orbView.retainsHistoryAcrossLaunches = enabled
        }
    }

    private func revealHistoryArchive() {
        let folder = historyArchive.directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              NSWorkspace.shared.open(folder) else {
            showHistoryMessage("无法打开本机存档目录", detail: "请检查本机存档是否已经生成。")
            return
        }
    }

    private func setHistoryRetention(_ retention: QuotaHistoryRetention) {
        guard orbView.historyRetention != retention else { return }
        if orbView.historyForArchive.values.contains(where: { $0.count > retention.rawValue }) {
            let alert = NSAlert()
            alert.messageText = "将每组采集记录减至 \(retention.title)？"
            alert.informativeText = "超出上限的旧记录将从内存和本机存档中清除。"
            alert.addButton(withTitle: "调整上限")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        QuotaPreferences.shared.set(retention.rawValue, forKey: QuotaHistoryRetention.defaultsKey)
        orbView.historyRetention = retention
        updateQuotaHistory(after: orbView.historyForArchive)
        guard orbView.retainsHistoryAcrossLaunches else { return }
        performHistoryArchiveOperation { try historyArchiveWriter.sync { try historyArchive.applyRetention() } }
    }

    private func resetHistoryArchive() {
        let alert = NSAlert()
        alert.messageText = "重置本机额度存档？"
        alert.informativeText = "确认后会清除本机存档并关闭跨启动保留。本次运行中的采集记录仍可查看。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重置存档")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performHistoryArchiveOperation {
            try historyArchiveWriter.sync { try historyArchive.setEnabled(false) }
            orbView.retainsHistoryAcrossLaunches = false
        }
    }

    private func historyDidChange(_ changes: [QuotaHistoryContext: [QuotaSnapshot]]) {
        updateQuotaHistory(after: changes)
        for (context, readings) in changes where readings.isEmpty { lowQuotaReminder.remove(context) }
        let snapshots = changes.mapValues(\.last)
        persistHistoryChange { try $0.update(snapshots) }
    }

    private func historyScopeCleared(_ scope: QuotaHistoryContext, removed: [QuotaHistoryContext]) {
        updateQuotaHistory(after: Dictionary(uniqueKeysWithValues: removed.map { ($0, []) }))
        lowQuotaReminder.removeScope(scope)
        persistHistoryChange(checkStoredState: true) { try $0.clearScope(scope) }
    }

    private func persistHistoryChange(checkStoredState: Bool = false,
                                      _ operation: @escaping (QuotaHistoryArchive) throws -> Bool) {
        guard checkStoredState || orbView.retainsHistoryAcrossLaunches else { return }
        let archive = historyArchive
        let generation = historyArchiveGeneration
        historyArchiveWriter.async { [weak self] in
            let result = Result { try operation(archive) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.historyArchiveGeneration == generation else { return }
                if case .success(let enabled) = result {
                    self.orbView.retainsHistoryAcrossLaunches = enabled
                }
                self.applyHistoryArchiveResult(result.map { _ in () })
            }
        }
    }

    private func clearHistory() {
        let previous = historyWindows.values
        historyWindows.removeAll()
        previous.forEach { $0.controller.close() }
        guard orbView.retainsHistoryAcrossLaunches else { return }
        performHistoryArchiveOperation { try historyArchiveWriter.sync { try historyArchive.clear() } }
    }

    private func saveHistory(_ contents: String, format: QuotaExport.Format) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        panel.nameFieldStringValue = "quota-history.\(format.rawValue)"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try Data(contents.utf8).write(to: destination, options: .atomic)
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "无法保存额度采集记录"
                alert.runModal()
            }
        }
    }

    private func importHistory() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = "读取"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let source = panel.url else { return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try QuotaPortableHistory.read(from: source) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    do {
                        try self.applyImportedHistory(result.get())
                    } catch {
                        self.showHistoryMessage("无法导入采集记录", detail: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func applyImportedHistory(_ history: QuotaPortableHistory) throws {
        let account = selectedAccount
        let (imported, futureReadings) = history.importableSnapshots(codexAccount: account)
        let skipped = futureReadings > 0 ? "已跳过 \(futureReadings) 条采集时间晚于本机的记录。" : ""
        guard !imported.isEmpty else {
            let detail = history.hasCodexReadings && account == nil
                ? "请先选择或添加接收记录的 Codex 额度账号。"
                : "该文件中没有可合并的采集记录。"
            showHistoryMessage("暂无可导入的采集记录", detail: detail + skipped)
            return
        }
        if imported.keys.contains(where: { $0.provider == .codex }) || (account == nil && history.hasCodexReadings) {
            let confirm = NSAlert()
            confirm.messageText = "导入额度采集记录？"
            if let account {
                confirm.informativeText = "文件中的 Codex 记录将合并到 \(accountName(for: account)) 的历史。"
                confirm.addButton(withTitle: "导入")
            } else {
                confirm.informativeText = "当前没有选中的 Codex 额度账号。可先导入文件中的其他来源。"
                confirm.addButton(withTitle: "导入其他来源")
            }
            confirm.addButton(withTitle: "取消")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }

        if orbView.retainsHistoryAcrossLaunches {
            historyArchiveGeneration = UUID()
            orbView.retainsHistoryAcrossLaunches = try historyArchiveWriter.sync { try historyArchive.mergeImported(imported) }
            applyHistoryArchiveResult(.success(()))
        }
        orbView.mergeImportedHistory(imported)
        updateQuotaHistory(after: imported)
        showHistoryMessage("采集记录已合并", detail: "可从“最近读取的额度”查看导入的来源和趋势。" + skipped)
    }

    private func showHistoryMessage(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "关闭")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func performHistoryArchiveOperation(_ operation: () throws -> Void) {
        historyArchiveGeneration = UUID()
        applyHistoryArchiveResult(Result { try operation() })
    }

    private func applyHistoryArchiveResult(_ result: Result<Void, Error>) {
        switch result {
        case .success: orbView.historyArchiveError = nil
        case .failure(let error): orbView.historyArchiveError = "本机历史记录暂不可用：\(error.localizedDescription)"
        }
    }

    private func setResetDisplay(_ mode: OrbResetDisplay) {
        guard orbView.resetDisplay != mode else { return }
        orbView.resetDisplay = mode
        QuotaPreferences.shared.set(mode.rawValue, forKey: OrbResetDisplay.defaultsKey)
        scheduleCountdownTimer()
    }

    private func scheduleCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        guard orbIsActive, !orbView.menuBarOnly, orbView.resetDisplay == .countdown else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, self.orbView.state.snapshot != nil else { return }
            self.orbView.needsDisplay = true
        }
        timer.tolerance = 1
        countdownTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func setRefreshCadence(_ cadence: QuotaRefreshCadence) {
        QuotaPreferences.shared.set(cadence.rawValue, forKey: QuotaRefreshCadence.defaultsKey)
        guard orbView.refreshCadence != cadence else { return }
        orbView.refreshCadence = cadence
        scheduleRefreshTimer()
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if orbIsActive, orbView.provider == .claudeCode, orbView.refreshCadence != .off {
            claudeCacheMonitor.start()
        } else {
            claudeCacheMonitor.stop()
        }
        guard orbIsActive, let interval = orbView.refreshCadence.interval,
              client != nil || pollingClient != nil || orbView.provider == .claudeCode else { return }

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshDisplayedQuota()
        }
        timer.tolerance = min(5, interval / 10)
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func startCodexClient() {
        guard let selectedAccount else {
            orbView.state = .failed("尚未添加额度账号，请右键添加")
            return
        }

        let codexHome: URL?
        do {
            codexHome = try CodexAccountProfile.homeURL(for: selectedAccount)
        } catch {
            orbView.state = .failed("无法创建额度账号目录：\(error.localizedDescription)")
            return
        }

        orbView.state = .loading
        let clientAccount = selectedAccount
        let client = CodexQuotaClient(codexHome: codexHome)
        client.onRefreshing = { [weak self, weak client] in
            guard let self, let client, self.client === client else { return }
            self.orbView.state.beginRefresh()
        }
        client.onReport = { [weak self, weak client] report in
            guard let self, let client, self.client === client else { return }
            self.orbView.codexMeteredQuotas = report.additional
            self.orbView.state = .loaded(report.primary)
            self.workspaceModel?.noteCodex(clientAccount, report: report)
        }
        client.onAccount = { [weak self, weak client] account in
            guard let self, let client, self.client === client else { return }
            let previousStatus = self.accountStatuses[clientAccount]
            if case .signedIn(let previous) = previousStatus,
               let account, previous.email != account.email {
                self.orbView.forgetQuota(for: .codex, account: clientAccount)
                self.orbView.state = .loading
            }
            self.accountStatuses[clientAccount] = account.map(CodexAccountStatus.signedIn) ?? .signedOut
            self.updateAccountMenuState()
            if account == nil {
                self.workspaceModel?.noteCodexFailure(clientAccount, error: WorkspaceError.unauthorized)
                if previousStatus != .signedOut { self.orbView.forgetQuota(for: .codex, account: clientAccount) }
                guard !self.orbView.isCodexLoginPending else { return }
                let name = self.accountName(for: clientAccount)
                self.orbView.state = .failed("\(name)未登录，请右键登录")
            }
        }
        client.onLoginPendingChanged = { [weak self, weak client] pending in
            guard let self, let client, self.client === client else { return }
            self.orbView.isCodexLoginPending = pending
            if pending { self.orbView.state = .loading }
        }
        client.onLoginURL = { [weak self, weak client] url in
            guard let self, let client, self.client === client else { return }
            NSApp.activate(ignoringOtherApps: true)
            if !NSWorkspace.shared.open(url) {
                self.orbView.state = .failed("无法打开 ChatGPT 登录页面")
                client.cancelChatGPTLogin()
            }
        }
        client.onError = { [weak self, weak client] error in
            guard let self, let client, self.client === client else { return }
            self.orbView.state.recordFailure(error.localizedDescription)
            self.workspaceModel?.noteCodexFailure(clientAccount, error: error)
        }
        self.client = client
        client.start()
        if pendingAccountLogin == clientAccount {
            pendingAccountLogin = nil
            let replacingExisting = pendingLoginReplacesExisting
            pendingLoginReplacesExisting = false
            client.loginWithChatGPT(replacingExisting: replacingExisting)
        }
    }

    private func startPollingClient(_ client: PollingQuotaClient) {
        orbView.beginPollingWithRecentQuota()
        client.onRefreshing = { [weak self, weak client] in
            guard let self, let client, self.pollingClient === client else { return }
            self.orbView.state.beginRefresh()
        }
        client.onResult = { [weak self, weak client] result in
            guard let self, let client, self.pollingClient === client else { return }
            switch result {
            case .success(let snapshot): self.orbView.state = .loaded(snapshot)
            case .failure(let error): self.orbView.state.recordFailure(error.localizedDescription)
            }
        }
        pollingClient = client
        client.refresh()
    }

    private func refreshClaudeQuota() {
        if orbView.refreshCadence != .off { claudeCacheMonitor.start() }
        do {
            orbView.state = try ClaudeQuotaCache.read()
        } catch {
            orbView.state.recordFailure(error.localizedDescription)
        }
    }

    private func refreshDisplayedQuota() {
        guard orbIsActive else { return }
        if let client {
            client.refresh()
        } else if let pollingClient {
            pollingClient.refresh()
        } else if orbView.provider == .claudeCode {
            refreshClaudeQuota()
        } else {
            startCodexClient()
            scheduleRefreshTimer()
        }
    }

    private func stopOrb(hideWindow: Bool = true) {
        orbIsActive = false
        claudeCacheMonitor.stop()
        refreshTimer?.invalidate()
        refreshTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        client?.stop()
        client = nil
        orbView.isCodexLoginPending = false
        pollingClient?.stop()
        pollingClient = nil
        if hideWindow {
            window.orderOut(nil)
            removeStatusItem()
        }
    }

    private func toggleMenuBarQuota() {
        orbView.showsMenuBarQuota.toggle()
        QuotaPreferences.shared.set(orbView.showsMenuBarQuota, forKey: QuotaPreferences.menuBarEnabledKey)
        if !orbView.showsMenuBarQuota { setMenuBarOnly(false) }
        reconcileStatusItem()
    }

    private func setMenuBarOnly(_ menuBarOnly: Bool) {
        guard orbView.menuBarOnly != menuBarOnly else { return }
        orbView.menuBarOnly = menuBarOnly
        QuotaPreferences.shared.set(menuBarOnly, forKey: QuotaPreferences.menuBarOnlyKey)
        reconcileWindowVisibility()
        scheduleCountdownTimer()
    }

    private func toggleMenuBarSourceName() {
        orbView.showsMenuBarSourceName.toggle()
        QuotaPreferences.shared.set(orbView.showsMenuBarSourceName, forKey: QuotaPreferences.menuBarSourceNameKey)
    }

    private func toggleAccountEmail() {
        orbView.hidesAccountEmail.toggle()
        QuotaPreferences.shared.set(orbView.hidesAccountEmail, forKey: QuotaPreferences.hidesAccountEmailKey)
        updateHistoryWindowTitles()
    }

    private func togglePositionLock() {
        orbView.isPositionLocked.toggle()
        QuotaPreferences.shared.set(orbView.isPositionLocked, forKey: QuotaPreferences.orbPositionLockedKey)
    }

    private func showAbout() {
        let build = QuotaBuildInformation.current
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "额度悬浮球",
            .applicationVersion: build.version,
        ]
        if let details = build.aboutDetails { options[.version] = details }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    private func setOrbOpacity(_ opacity: OrbOpacityPreference) {
        orbView.opacityPreference = opacity
        applyOrbDisplayOptions()
        QuotaPreferences.shared.set(opacity.rawValue, forKey: OrbOpacityPreference.defaultsKey)
    }

    private func applyOrbDisplayOptions() {
        let workspace = NSWorkspace.shared
        window.alphaValue = orbView.opacityPreference.alpha(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency
        )
        orbView.increasesContrast = workspace.accessibilityDisplayShouldIncreaseContrast
    }

    @objc private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.applyOrbDisplayOptions() }
    }

    private func setWarningThreshold(_ threshold: QuotaWarningThreshold) {
        if orbView.warningThreshold != threshold { lowQuotaReminder = QuotaLowReminder() }
        orbView.warningThreshold = threshold
        for window in historyWindows.values { window.model.warningThreshold = threshold }
        QuotaPreferences.shared.set(threshold.rawValue, forKey: QuotaWarningThreshold.defaultsKey)
    }

    private func editWarningThreshold() {
        let alert = NSAlert()
        alert.messageText = "设置低额度警戒线"
        alert.informativeText = "输入 0 到 100 之间的整数百分比。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        input.integerValue = orbView.warningThreshold.rawValue
        input.setAccessibilityLabel("低额度警戒线百分比")
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        NSApp.activate(ignoringOtherApps: true)
        while alert.runModal() == .alertFirstButtonReturn {
            let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let percent = Int(text), let threshold = QuotaWarningThreshold(rawValue: percent) {
                setWarningThreshold(threshold)
                return
            }
            alert.informativeText = "请输入 0 到 100 之间的整数百分比，例如 15。"
        }
    }

    private func toggleLowQuotaSound() {
        orbView.lowQuotaSoundEnabled.toggle()
        if !orbView.lowQuotaNotificationEnabled { lowQuotaReminder = QuotaLowReminder() }
        QuotaPreferences.shared.set(orbView.lowQuotaSoundEnabled, forKey: QuotaPreferences.lowQuotaSoundKey)
    }

    private func toggleLowQuotaNotifications() {
        guard orbView.supportsLowQuotaNotifications, !isRequestingNotifications else { return }
        if orbView.lowQuotaNotificationEnabled {
            setLowQuotaNotifications(false)
            return
        }
        isRequestingNotifications = true
        NSApp.activate(ignoringOtherApps: true)
        quotaNotifications.requestAuthorization { [weak self] granted, error in
            guard let self else { return }
            self.isRequestingNotifications = false
            self.setLowQuotaNotifications(granted)
            if !granted {
                let alert = NSAlert()
                alert.messageText = "无法启用低额度通知"
                alert.informativeText = error?.localizedDescription ?? "请在系统设置的“通知”中允许额度悬浮球发送通知。"
                alert.addButton(withTitle: "关闭")
                alert.runModal()
            }
        }
    }

    private func setLowQuotaNotifications(_ enabled: Bool) {
        orbView.lowQuotaNotificationEnabled = enabled
        orbView.lowQuotaNotificationMessage = nil
        if !orbView.lowQuotaSoundEnabled { lowQuotaReminder = QuotaLowReminder() }
        QuotaPreferences.shared.set(enabled, forKey: QuotaPreferences.lowQuotaNotificationKey)
    }

    private func checkNotificationAuthorization() {
        guard orbView.lowQuotaNotificationEnabled else { return }
        quotaNotifications.checkAuthorization { [weak self] enabled in
            guard let self, self.orbView.lowQuotaNotificationEnabled, !enabled else { return }
            self.recordNotificationPermissionLoss()
        }
    }

    private func recordNotificationPermissionLoss() {
        setLowQuotaNotifications(false)
        orbView.lowQuotaNotificationMessage = "macOS 通知权限已关闭"
    }

    private func handleLowQuota(_ scope: QuotaHistoryContext, snapshot: QuotaSnapshot) {
        guard orbView.lowQuotaSoundEnabled || orbView.lowQuotaNotificationEnabled, !orbView.isReminderPaused() else { return }
        let events = lowQuotaReminder.events(for: scope, snapshot: snapshot, threshold: orbView.warningThreshold,
                                             periods: orbView.reminderPeriods)
        guard !events.isEmpty else { return }
        if orbView.lowQuotaSoundEnabled { NSSound.beep() }
        if orbView.lowQuotaNotificationEnabled {
            quotaNotifications.post(scope: scope, events: events) { [weak self] error in
                guard let self, self.orbView.lowQuotaNotificationEnabled else { return }
                if let error, QuotaNotificationService.isAuthorizationError(error) {
                    self.recordNotificationPermissionLoss()
                } else {
                    self.orbView.lowQuotaNotificationMessage = error.map { "通知发送失败：\($0.localizedDescription)" }
                }
            }
        }
    }

    private func toggleReminderPause() {
        let now = Date()
        let end = orbView.isReminderPaused(at: now) ? nil : now.addingTimeInterval(3_600)
        orbView.reminderPausedUntil = end
        QuotaPreferences.shared.set(end, forKey: QuotaPreferences.lowQuotaPauseUntilKey)
    }

    private func toggleReminderPeriod(_ period: QuotaPeriod) {
        if !orbView.reminderPeriods.insert(period).inserted {
            orbView.reminderPeriods.remove(period)
        }
        lowQuotaReminder.reset(period)
        let values = QuotaPeriod.allCases.filter(orbView.reminderPeriods.contains).map(\.rawValue)
        QuotaPreferences.shared.set(values, forKey: QuotaPreferences.lowQuotaPeriodsKey)
    }

    private func toggleWindowLevel() {
        orbView.staysOnTop.toggle()
        QuotaPreferences.shared.set(orbView.staysOnTop, forKey: QuotaPreferences.orbStaysOnTopKey)
        window.level = orbView.staysOnTop ? .floating : .normal
        reconcileWindowVisibility()
    }

    private func toggleOrbSpaces() {
        orbView.showsOnAllSpaces.toggle()
        QuotaPreferences.shared.set(orbView.showsOnAllSpaces, forKey: QuotaPreferences.orbAllSpacesKey)
        applyOrbSpacePreference()
    }

    private func applyOrbSpacePreference() {
        window.collectionBehavior = orbView.showsOnAllSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            : [.stationary, .fullScreenDisallowsTiling]
    }

    private func reconcileWindowVisibility() {
        guard orbIsActive, !workspaceOnly, !orbView.menuBarOnly else {
            window.orderOut(nil)
            return
        }
        window.setFrameOrigin(restoredOrDefaultOrigin())
        window.orderFrontRegardless()
    }

    private func reconcileStatusItem() {
        guard orbIsActive, !workspaceOnly, orbView.showsMenuBarQuota else {
            removeStatusItem()
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.imagePosition = .imageLeading
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        }
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        button.image = orbView.isDisplayedQuotaLow ? Self.lowQuotaMenuBarImage ?? Self.quotaMenuBarImage : Self.quotaMenuBarImage
        button.title = orbView.menuBarTitle
        button.toolTip = orbView.toolTip
        button.setAccessibilityLabel(orbView.accessibilityLabel())
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        orbView.populateMenu(menu)
    }

    private func switchProvider(to provider: QuotaProvider) {
        guard orbView.provider != provider else { return }
        stopOrb(hideWindow: false)
        orbView.startupPeriodOverride = nil
        orbView.provider = provider
        QuotaPreferences.shared.set(provider.rawValue, forKey: QuotaPreferences.selectedProviderKey)
        startOrb()
    }

    private func configureOpenCodeGo() {
        let alert = NSAlert()
        alert.messageText = "设置 OpenCode Go API 密钥"
        alert.informativeText = "使用 OpenCode Go 订阅的 API 密钥。密钥会保存在 macOS 钥匙串中。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "清除已保存密钥")
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.placeholderString = "OpenCode Go API 密钥"
        input.setAccessibilityLabel("OpenCode Go API 密钥")
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        do {
            switch response {
            case .alertFirstButtonReturn:
                let key = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !key.contains(where: \.isWhitespace) else {
                    showOpenCodeGoKeyError("请输入有效的 OpenCode Go API 密钥")
                    return
                }
                try OpenCodeGoKeychain.save(key)
            case .alertThirdButtonReturn:
                try OpenCodeGoKeychain.remove()
            default:
                return
            }
        } catch {
            showOpenCodeGoKeyError("无法更新 macOS 钥匙串中的 OpenCode Go 密钥")
            return
        }
        // A changed key may refer to a different account.
        orbView.forgetQuota(for: .openCodeGo)
        guard orbView.provider == .openCodeGo, orbIsActive else { return }
        stopOrb(hideWindow: false)
        startOrb()
    }

    private func showOpenCodeGoKeyError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.runModal()
    }

    private func switchAccount(to account: CodexAccountSlot) {
        guard accounts.contains(account), account != selectedAccount else { return }
        if selectedAccount != nil { orbView.startupPeriodOverride = nil }
        selectedAccount = account
        QuotaPreferences.shared.set(account.rawValue, forKey: CodexAccountProfile.selectedAccountDefaultsKey)
        updateAccountMenuState()
        stopOrb(hideWindow: false)
        startOrb()
    }

    private func addAccount() {
        let account = CodexAccountProfile.createAccount()
        accounts.append(account)
        accountStatuses[account] = .signedOut
        pendingAccountLogin = account
        pendingLoginReplacesExisting = false
        switchAccount(to: account)
    }

    private func loginAccount(_ account: CodexAccountSlot) {
        guard accounts.contains(account) else { return }
        let replacingExisting = CodexAccountProfile.hasStoredCredentials(for: account)
        if replacingExisting {
            orbView.forgetQuota(for: .codex, account: account)
        }
        if selectedAccount == account {
            orbView.state = .loading
            if let client {
                client.loginWithChatGPT(replacingExisting: replacingExisting)
            } else {
                pendingAccountLogin = account
                pendingLoginReplacesExisting = replacingExisting
                if orbIsActive { startCodexClient() }
                else { startOrb() }
            }
        } else {
            pendingAccountLogin = account
            pendingLoginReplacesExisting = replacingExisting
            switchAccount(to: account)
        }
    }

    private func renameAccount(_ account: CodexAccountSlot) {
        guard accounts.contains(account) else { return }
        let alert = NSAlert()
        alert.messageText = "重命名额度账号"
        alert.informativeText = "可输入便于区分的名称，留空恢复默认名称。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = CodexAccountProfile.name(for: account) ?? ""
        input.placeholderString = "额度账号名称"
        input.setAccessibilityLabel("额度账号名称")
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, accounts.contains(account) else { return }
        CodexAccountProfile.setName(input.stringValue, for: account)
        updateAccountMenuState()
        updateHistoryWindowTitles()
    }

    private func deleteAccount(_ account: CodexAccountSlot) {
        guard accounts.contains(account) else { return }
        let name = accountName(for: account)
        do {
            guard try !WorkspaceStore.local.load().referencesAccount(account.rawValue) else {
                throw WorkspaceError.accountInUse
            }
        } catch {
            let failure = NSAlert(error: error)
            failure.messageText = "无法删除\(name)"
            failure.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "删除\(name)？"
        alert.informativeText = "这会从本机永久删除该额度账号保存的登录凭据。当前 Codex CLI/桌面端账号不会受影响。"
        alert.addButton(withTitle: "删除账号")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let wasSelected = selectedAccount == account
        if wasSelected {
            stopOrb(hideWindow: false)
        }
        do {
            try CodexAccountProfile.deleteAccount(account)
            orbView.forgetQuota(for: .codex, account: account)
            accounts.removeAll { $0 == account }
            accountStatuses.removeValue(forKey: account)
            if pendingAccountLogin == account {
                pendingAccountLogin = nil
                pendingLoginReplacesExisting = false
            }
            if wasSelected {
                orbView.startupPeriodOverride = nil
                selectedAccount = accounts.first
                if let selectedAccount {
                    QuotaPreferences.shared.set(selectedAccount.rawValue, forKey: CodexAccountProfile.selectedAccountDefaultsKey)
                } else {
                    QuotaPreferences.shared.removeObject(forKey: CodexAccountProfile.selectedAccountDefaultsKey)
                }
            }
            updateAccountMenuState()
            if wasSelected {
                startOrb()
            }
        } catch {
            if wasSelected {
                startOrb()
            }
            let failure = NSAlert(error: error)
            failure.messageText = "无法删除\(name)"
            NSApp.activate(ignoringOtherApps: true)
            failure.runModal()
        }
    }

    private func updateAccountMenuState() {
        guard orbView != nil else { return }
        orbView.accounts = accounts
        orbView.selectedAccount = selectedAccount
        orbView.accountStatuses = accountStatuses
        orbView.accountNames = Dictionary(uniqueKeysWithValues: accounts.compactMap { account in
            CodexAccountProfile.name(for: account).map { (account, $0) }
        })
        workspaceModel?.reload()
    }

    private func accountName(for account: CodexAccountSlot) -> String {
        if let name = CodexAccountProfile.name(for: account) { return name }
        if !orbView.hidesAccountEmail, case .signedIn(let summary) = accountStatuses[account], let email = summary.email {
            return email
        }
        let index = accounts.firstIndex(of: account).map { $0 + 1 } ?? 1
        return "额度账号 \(index)"
    }

    private func quitOrHideOrb() {
        guard followCodex else {
            NSApp.terminate(nil)
            return
        }
        suppressOrbUntilCodexStops = true
        stopOrb()
    }

    private func isCodexRunning(excluding processID: pid_t? = nil) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Self.codexBundleIdentifier && !$0.isTerminated && $0.processIdentifier != processID
        }
    }

    @objc private func workspaceApplicationDidLaunch(_ notification: Notification) {
        guard application(from: notification)?.bundleIdentifier == Self.codexBundleIdentifier else { return }
        codexGUIRunning = true
        reconcileOrbVisibility()
    }

    @objc private func workspaceApplicationDidTerminate(_ notification: Notification) {
        guard let stopped = application(from: notification), stopped.bundleIdentifier == Self.codexBundleIdentifier else { return }
        codexGUIRunning = isCodexRunning(excluding: stopped.processIdentifier)
        reconcileOrbVisibility()
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.checkNotificationAuthorization()
            let wasActive = self.orbIsActive
            if self.monitorsCodexDesktop {
                self.codexGUIRunning = self.isCodexRunning()
                self.reconcileOrbVisibility()
            }
            guard self.orbIsActive else { return }
            self.orbView.refreshLocalTimeFormatting()
            guard wasActive, self.refreshTimer != nil else { return }
            self.scheduleRefreshTimer()
            self.refreshDisplayedQuota()
        }
    }

    private func reconcileOrbVisibility() {
        let codexRunning = codexGUIRunning || codexCLIRunning
        if suppressOrbUntilCodexStops {
            if !codexRunning {
                suppressOrbUntilCodexStops = false
            }
            stopOrb()
        } else if codexRunning {
            startOrb()
        } else {
            stopOrb()
        }
    }

    private func application(from notification: Notification) -> NSRunningApplication? {
        notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    private var savedOrbOrigin: NSPoint? {
        let defaults = QuotaPreferences.shared
        guard let x = defaults.object(forKey: "orb.x") as? Double, x.isFinite,
              let y = defaults.object(forKey: "orb.y") as? Double, y.isFinite else { return nil }
        return NSPoint(x: x, y: y)
    }

    private func restoredOrDefaultOrigin() -> NSPoint {
        guard let savedOrbOrigin else { return defaultOrbOrigin() }
        return OrbWindowPlacement.constrainedOrigin(
            savedOrbOrigin, size: orbSize, visibleFrames: NSScreen.screens.map(\.visibleFrame)
        )
    }

    private func defaultOrbOrigin() -> NSPoint {
        let visible = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        return OrbWindowPlacement.defaultOrigin(size: orbSize, visibleFrame: visible)
    }

    private func resetOrbPosition() {
        window.setFrameOrigin(defaultOrbOrigin())
        saveOrbOrigin(window.frame.origin)
    }

    private func moveOrb(to corner: OrbWindowPlacement.Corner) {
        let currentScreen = window.screen ?? NSScreen.screens.first
        guard let visibleFrame = currentScreen?.visibleFrame else { return }
        let origin = OrbWindowPlacement.origin(at: corner, size: orbSize, visibleFrame: visibleFrame)
        window.setFrameOrigin(origin)
        saveOrbOrigin(origin)
    }

    private func orbDisplayChoices() -> [QuotaOrbView.DisplayChoice] {
        let screens = NSScreen.screens
        let grouped = Dictionary(grouping: screens, by: \.localizedName)
        let current = window.screen.flatMap(displayID(for:))
        return screens.enumerated().compactMap { index, screen in
            guard let id = displayID(for: screen) else { return nil }
            let name = screen.localizedName
            let title = (grouped[name]?.count ?? 0) > 1 ? "\(name) (\(index + 1))" : name
            return QuotaOrbView.DisplayChoice(id: id, title: title, isCurrent: id == current)
        }
    }

    private func displayID(for screen: NSScreen) -> UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    private func moveOrb(toDisplay display: UInt32) {
        guard let target = NSScreen.screens.first(where: { displayID(for: $0) == display }) else { return }
        let origin: NSPoint
        if let current = window.screen {
            origin = OrbWindowPlacement.translatedOrigin(window.frame.origin, size: orbSize,
                                                        from: current.visibleFrame, to: target.visibleFrame)
        } else {
            origin = OrbWindowPlacement.defaultOrigin(size: orbSize, visibleFrame: target.visibleFrame)
        }
        window.setFrameOrigin(origin)
        saveOrbOrigin(origin)
    }

    private func resizeOrb(to preference: OrbSizePreference) {
        guard orbSizePreference != preference else { return }
        if let origin = savedOrbOrigin {
            let offset = (orbSize.width - preference.size.width) / 2
            saveOrbOrigin(NSPoint(x: origin.x + offset, y: origin.y + offset))
        }
        orbSizePreference = preference
        orbView.sizePreference = preference
        QuotaPreferences.shared.set(preference.rawValue, forKey: OrbSizePreference.defaultsKey)
        window.setFrame(NSRect(origin: restoredOrDefaultOrigin(), size: orbSize), display: true)
    }

    private func saveOrbOrigin(_ origin: NSPoint) {
        QuotaPreferences.shared.set(origin.x, forKey: "orb.x")
        QuotaPreferences.shared.set(origin.y, forKey: "orb.y")
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        window?.setFrameOrigin(restoredOrDefaultOrigin())
    }

    @objc private func systemTimeZoneDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.orbView.refreshLocalTimeFormatting() }
    }

    private func finishOrbDrag() {
        let origin = OrbWindowPlacement.constrainedOrigin(
            window.frame.origin,
            size: window.frame.size,
            visibleFrames: NSScreen.screens.map(\.visibleFrame)
        )
        window.setFrameOrigin(origin)
        saveOrbOrigin(origin)
    }
}
