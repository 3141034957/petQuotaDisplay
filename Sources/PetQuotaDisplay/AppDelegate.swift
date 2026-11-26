import AppKit
import QuotaCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let codexBundleIdentifier = "com.openai.codex"
    private static let selectedAccountDefaultsKey = "quota.selectedAccount"
    private static let selectedProviderDefaultsKey = "quota.selectedProvider"

    private var orbSizePreference = OrbSizePreference(
        rawValue: UserDefaults.standard.integer(forKey: OrbSizePreference.defaultsKey)
    ) ?? .standard
    private var orbSize: NSSize { orbSizePreference.size }
    private let followCodex: Bool
    private var client: CodexQuotaClient?
    private var pollingClient: PollingQuotaClient?
    private var window: NSWindow!
    private var orbView: QuotaOrbView!
    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
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

    init(followCodex: Bool) {
        self.followCodex = followCodex
        let accounts = CodexAccountProfile.loadAccounts()
        self.accounts = accounts
        let savedAccount = UserDefaults.standard.string(forKey: Self.selectedAccountDefaultsKey)
        let restoredAccount = savedAccount.flatMap(CodexAccountSlot.init(rawValue:))
        self.selectedAccount = restoredAccount.flatMap { accounts.contains($0) ? $0 : nil } ?? accounts.first
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        for account in accounts where CodexAccountProfile.hasStoredCredentials(for: account) {
            accountStatuses[account] = .stored
        }
        createWindow()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        if followCodex {
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
            codexGUIRunning = isCodexRunning
            let cliMonitor = CodexCLIProcessMonitor()
            cliMonitor.onRunningStateChanged = { [weak self] isRunning in
                self?.codexCLIRunning = isRunning
                self?.reconcileOrbVisibility()
            }
            self.cliMonitor = cliMonitor
            cliMonitor.start()
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
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        window.animationBehavior = .utilityWindow

        orbView = QuotaOrbView(frame: NSRect(origin: .zero, size: orbSize))
        orbView.autoresizingMask = [.width, .height]
        let savedProvider = UserDefaults.standard.string(forKey: Self.selectedProviderDefaultsKey)
        orbView.provider = savedProvider.flatMap(QuotaProvider.init(rawValue:)) ?? .codex
        orbView.refreshCadence = QuotaRefreshCadence.load()
        orbView.sizePreference = orbSizePreference
        let savedResetDisplay = UserDefaults.standard.string(forKey: OrbResetDisplay.defaultsKey)
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
        orbView.onSelectAccount = { [weak self] account in self?.switchAccount(to: account) }
        orbView.onAddAccount = { [weak self] in self?.addAccount() }
        orbView.onLoginAccount = { [weak self] account in self?.loginAccount(account) }
        orbView.onRenameAccount = { [weak self] account in self?.renameAccount(account) }
        orbView.onDeleteAccount = { [weak self] account in self?.deleteAccount(account) }
        orbView.onConfigureOpenCodeGo = { [weak self] in self?.configureOpenCodeGo() }
        orbView.quitMenuTitle = followCodex ? "本次隐藏悬浮球" : "退出额度悬浮球"
        updateAccountMenuState()
        window.contentView = orbView
    }

    private func startOrb() {
        guard !orbIsActive else { return }
        orbIsActive = true
        window.setFrameOrigin(restoredOrDefaultOrigin())
        window.orderFrontRegardless()

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

    private func setResetDisplay(_ mode: OrbResetDisplay) {
        guard orbView.resetDisplay != mode else { return }
        orbView.resetDisplay = mode
        UserDefaults.standard.set(mode.rawValue, forKey: OrbResetDisplay.defaultsKey)
        scheduleCountdownTimer()
    }

    private func scheduleCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        guard orbIsActive, orbView.resetDisplay == .countdown else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, self.orbView.state.snapshot != nil else { return }
            self.orbView.needsDisplay = true
        }
        timer.tolerance = 1
        countdownTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func setRefreshCadence(_ cadence: QuotaRefreshCadence) {
        guard orbView.refreshCadence != cadence else { return }
        orbView.refreshCadence = cadence
        UserDefaults.standard.set(cadence.rawValue, forKey: QuotaRefreshCadence.defaultsKey)
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
            self.accountStatuses[clientAccount] = account.map(CodexAccountStatus.signedIn) ?? .signedOut
            self.updateAccountMenuState()
            if account == nil {
                let name = self.accountName(for: clientAccount)
                self.orbView.state = .failed("\(name)未登录，请右键登录")
            }
        }
        client.onLoginURL = { [weak self, weak client] url in
            guard let self, let client, self.client === client else { return }
            NSApp.activate(ignoringOtherApps: true)
            if !NSWorkspace.shared.open(url) {
                self.orbView.state = .failed("无法打开 ChatGPT 登录页面")
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
        orbView.state = .loading
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
        pollingClient?.stop()
        pollingClient = nil
        if hideWindow {
            window.orderOut(nil)
        }
    }

    private func switchProvider(to provider: QuotaProvider) {
        guard orbView.provider != provider else { return }
        stopOrb(hideWindow: false)
        orbView.provider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: Self.selectedProviderDefaultsKey)
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
        selectedAccount = account
        UserDefaults.standard.set(account.rawValue, forKey: Self.selectedAccountDefaultsKey)
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
            accounts.removeAll { $0 == account }
            accountStatuses.removeValue(forKey: account)
            if pendingAccountLogin == account {
                pendingAccountLogin = nil
                pendingLoginReplacesExisting = false
            }
            if wasSelected {
                selectedAccount = accounts.first
                if let selectedAccount {
                    UserDefaults.standard.set(selectedAccount.rawValue, forKey: Self.selectedAccountDefaultsKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: Self.selectedAccountDefaultsKey)
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
        if case .signedIn(let summary) = accountStatuses[account], let email = summary.email {
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

    private var isCodexRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Self.codexBundleIdentifier && !$0.isTerminated
        }
    }

    @objc private func workspaceApplicationDidLaunch(_ notification: Notification) {
        guard application(from: notification)?.bundleIdentifier == Self.codexBundleIdentifier else { return }
        codexGUIRunning = true
        reconcileOrbVisibility()
    }

    @objc private func workspaceApplicationDidTerminate(_ notification: Notification) {
        guard application(from: notification)?.bundleIdentifier == Self.codexBundleIdentifier else { return }
        codexGUIRunning = false
        reconcileOrbVisibility()
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
        let defaults = UserDefaults.standard
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
        UserDefaults.standard.set(preference.rawValue, forKey: OrbSizePreference.defaultsKey)
        window.setFrame(NSRect(origin: restoredOrDefaultOrigin(), size: orbSize), display: true)
    }

    private func saveOrbOrigin(_ origin: NSPoint) {
        UserDefaults.standard.set(origin.x, forKey: "orb.x")
        UserDefaults.standard.set(origin.y, forKey: "orb.y")
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        window?.setFrameOrigin(restoredOrDefaultOrigin())
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
