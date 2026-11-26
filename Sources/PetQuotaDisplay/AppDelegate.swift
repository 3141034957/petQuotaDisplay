import AppKit
import QuotaCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let codexBundleIdentifier = "com.openai.codex"
    private static let floatingOrbDefaultsKey = "orb.staysOnTop"
    private static let quotaMenuBarImage = NSImage(systemSymbolName: "gauge", accessibilityDescription: nil)
    private static let lowQuotaMenuBarImage = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)

    private var orbSizePreference = OrbSizePreference.load()
    private var orbSize: NSSize { orbSizePreference.size }
    private let displayOptions: QuotaDisplayOptions
    private var monitorsCodexDesktop: Bool { displayOptions.mode?.monitorsCodexDesktop == true }
    private var monitorsCodexCLI: Bool { displayOptions.mode?.monitorsCodexCLI == true }
    private var followCodex: Bool { monitorsCodexDesktop || monitorsCodexCLI }
    private var forceOrbVisible: Bool { displayOptions.mode == .forceOrb }
    private var client: CodexQuotaClient?
    private var pollingClient: PollingQuotaClient?
    private var window: NSWindow!
    private var orbView: QuotaOrbView!
    private var refreshTimer: Timer?
    private var historyWindowController: NSWindowController?
    private var historyWindowModel: QuotaHistoryWindowModel?
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
        NSApp.setActivationPolicy(.accessory)
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
        if followCodex {
            reconcileOrbVisibility()
        } else {
            startOrb()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        let staysOnTop = forceOrbVisible || (QuotaPreferences.shared.object(forKey: Self.floatingOrbDefaultsKey) as? Bool ?? true)
        window.level = staysOnTop ? .floating : .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        window.animationBehavior = .utilityWindow

        orbView = QuotaOrbView(frame: NSRect(origin: .zero, size: orbSize))
        orbView.autoresizingMask = [.width, .height]
        orbView.provider = displayOptions.provider ?? QuotaPreferences.selectedProvider()
        orbView.startupPeriodOverride = displayOptions.period
        orbView.refreshCadence = displayOptions.refreshCadence ?? QuotaRefreshCadence.load()
        orbView.showsMenuBarQuota = QuotaPreferences.shared.bool(forKey: QuotaPreferences.menuBarEnabledKey)
        orbView.hidesAccountEmail = QuotaPreferences.shared.bool(forKey: QuotaPreferences.hidesAccountEmailKey)
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
        orbView.staysOnTop = staysOnTop
        let savedResetDisplay = QuotaPreferences.shared.string(forKey: OrbResetDisplay.defaultsKey)
        orbView.resetDisplay = savedResetDisplay.flatMap(OrbResetDisplay.init(rawValue:)) ?? .time
        orbView.onSelectProvider = { [weak self] provider in self?.switchProvider(to: provider) }
        orbView.onSelectRefreshCadence = { [weak self] cadence in self?.setRefreshCadence(cadence) }
        orbView.onRefresh = { [weak self] in
            guard let self else { return }
            if self.client != nil { self.orbView.state.beginRefresh() }
            self.refreshDisplayedQuota()
        }
        orbView.onQuit = { [weak self] in self?.quitOrHideOrb() }
        orbView.onPositionChanged = { [weak self] in self?.finishOrbDrag() }
        orbView.onResetPosition = { [weak self] in self?.resetOrbPosition() }
        orbView.onSelectSize = { [weak self] size in self?.resizeOrb(to: size) }
        orbView.onSelectResetDisplay = { [weak self] mode in self?.setResetDisplay(mode) }
        orbView.onToggleMenuBarQuota = { [weak self] in self?.toggleMenuBarQuota() }
        orbView.onToggleMenuBarSourceName = { [weak self] in self?.toggleMenuBarSourceName() }
        orbView.onToggleAccountEmail = { [weak self] in self?.toggleAccountEmail() }
        orbView.onSelectWarningThreshold = { [weak self] threshold in self?.setWarningThreshold(threshold) }
        orbView.onToggleLowQuotaSound = { [weak self] in self?.toggleLowQuotaSound() }
        orbView.onToggleLowQuotaNotifications = { [weak self] in self?.toggleLowQuotaNotifications() }
        orbView.onToggleReminderPeriod = { [weak self] period in self?.toggleReminderPeriod(period) }
        orbView.onToggleReminderPause = { [weak self] in self?.toggleReminderPause() }
        orbView.onFreshQuota = { [weak self] scope, snapshot in self?.handleLowQuota(scope, snapshot: snapshot) }
        orbView.onToggleWindowLevel = { [weak self] in self?.toggleWindowLevel() }
        orbView.onRaiseOrb = { [weak self] in self?.reconcileWindowVisibility() }
        orbView.onToggleOrbVisibility = { [weak self] in
            guard let self, self.orbView.showsMenuBarQuota else { return }
            self.setMenuBarOnly(!self.orbView.menuBarOnly)
        }
        orbView.onPresentationChanged = { [weak self] in self?.updateStatusItem() }
        orbView.onShowQuotaHistory = { [weak self] context, readings in self?.showQuotaHistory(context: context, readings: readings) }
        orbView.onQuotaHistoryChanged = { [weak self] context, readings in self?.historyDidChange(context, readings: readings) }
        orbView.onQuotaHistoryCleared = { [weak self] in self?.clearHistory() }
        orbView.onToggleHistoryArchive = { [weak self] in self?.toggleHistoryArchive() }
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
        if let historyWindowController, let historyWindowModel, historyWindowModel.context == context {
            historyWindowModel.readings = readings
            NSApp.activate(ignoringOtherApps: true)
            historyWindowController.showWindow(nil)
            return
        }
        let model = QuotaHistoryWindowModel(context: context, readings: readings)
        historyWindowModel = model
        let content = NSHostingController(rootView: QuotaHistoryView(model: model))
        let controller: NSWindowController
        if let historyWindowController, let window = historyWindowController.window {
            window.contentViewController = content
            controller = historyWindowController
        } else {
            let historyWindow = NSWindow(contentViewController: content)
            historyWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            historyWindow.isReleasedWhenClosed = false
            historyWindow.setContentSize(NSSize(width: 540, height: 360))
            historyWindow.center()
            controller = NSWindowController(window: historyWindow)
            historyWindowController = controller
        }
        updateHistoryWindowTitle()
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    private func updateHistoryWindowTitle() {
        guard let context = historyWindowModel?.context else { return }
        let parts = [context.provider.title, context.account.map(accountName(for:)), "额度趋势"].compactMap { $0 }
        historyWindowController?.window?.title = parts.joined(separator: " · ")
    }

    private func showHistoryFromNotification(_ context: QuotaHistoryContext) {
        if let readings = orbView.historyForArchive[context], !readings.isEmpty {
            showQuotaHistory(context: context, readings: readings)
        } else {
            let alert = NSAlert()
            alert.messageText = "暂无此通知对应的采集记录"
            alert.addButton(withTitle: "关闭")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func updateQuotaHistory(context: QuotaHistoryContext, readings: [QuotaSnapshot]) {
        guard let historyWindowModel, historyWindowModel.context == context else { return }
        if readings.isEmpty {
            closeQuotaHistory()
        } else {
            historyWindowModel.readings = readings
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

    private func historyDidChange(_ context: QuotaHistoryContext, readings: [QuotaSnapshot]) {
        updateQuotaHistory(context: context, readings: readings)
        if readings.isEmpty { lowQuotaReminder.remove(context) }
        guard orbView.retainsHistoryAcrossLaunches else { return }
        let archive = historyArchive
        let latest = readings.last
        let generation = historyArchiveGeneration
        historyArchiveWriter.async { [weak self] in
            let result = Result { try archive.update(context, latest: latest) }
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
        closeQuotaHistory()
        guard orbView.retainsHistoryAcrossLaunches else { return }
        performHistoryArchiveOperation { try historyArchiveWriter.sync { try historyArchive.clear() } }
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

    private func closeQuotaHistory() {
        historyWindowController?.close()
        historyWindowController = nil
        historyWindowModel = nil
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
        }
        client.onAccount = { [weak self, weak client] account in
            guard let self, let client, self.client === client else { return }
            if case .signedIn(let previous) = self.accountStatuses[clientAccount],
               let account, previous.email != account.email {
                self.orbView.forgetQuota(for: .codex, account: clientAccount)
                self.orbView.state = .loading
            }
            self.accountStatuses[clientAccount] = account.map(CodexAccountStatus.signedIn) ?? .signedOut
            self.updateAccountMenuState()
            if account == nil {
                self.orbView.forgetQuota(for: .codex, account: clientAccount)
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
        updateHistoryWindowTitle()
    }

    private func setWarningThreshold(_ threshold: QuotaWarningThreshold) {
        if orbView.warningThreshold != threshold { lowQuotaReminder = QuotaLowReminder() }
        orbView.warningThreshold = threshold
        QuotaPreferences.shared.set(threshold.rawValue, forKey: QuotaWarningThreshold.defaultsKey)
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

    private func handleLowQuota(_ scope: QuotaReminderScope, snapshot: QuotaSnapshot) {
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
        QuotaPreferences.shared.set(orbView.staysOnTop, forKey: Self.floatingOrbDefaultsKey)
        window.level = orbView.staysOnTop ? .floating : .normal
        reconcileWindowVisibility()
    }

    private func reconcileWindowVisibility() {
        guard orbIsActive, !orbView.menuBarOnly else {
            window.orderOut(nil)
            return
        }
        window.setFrameOrigin(restoredOrDefaultOrigin())
        window.orderFrontRegardless()
    }

    private func reconcileStatusItem() {
        guard orbIsActive, orbView.showsMenuBarQuota else {
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
            client?.loginWithChatGPT(replacingExisting: replacingExisting)
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
        updateHistoryWindowTitle()
    }

    private func deleteAccount(_ account: CodexAccountSlot) {
        guard accounts.contains(account) else { return }
        let name = accountName(for: account)
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
