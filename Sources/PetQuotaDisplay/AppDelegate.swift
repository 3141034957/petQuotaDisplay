import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let codexBundleIdentifier = "com.openai.codex"
    private static let selectedAccountDefaultsKey = "quota.selectedAccount"

    private let orbSize = NSSize(width: 111, height: 111)
    private let followCodex: Bool
    private var client: CodexQuotaClient?
    private var window: NSWindow!
    private var orbView: QuotaOrbView!
    private var refreshTimer: Timer?
    private var cliMonitor: CodexCLIProcessMonitor?
    private var codexGUIRunning = false
    private var codexCLIRunning = false
    private var accounts: [CodexAccountSlot]
    private var selectedAccount: CodexAccountSlot
    private var accountStatuses: [CodexAccountSlot: CodexAccountStatus] = [:]
    private var pendingAccountLogin: CodexAccountSlot?
    private var pendingLoginReplacesExisting = false

    init(followCodex: Bool) {
        self.followCodex = followCodex
        let accounts = CodexAccountProfile.loadAccounts()
        self.accounts = accounts
        let savedAccount = UserDefaults.standard.string(forKey: Self.selectedAccountDefaultsKey)
        let restoredAccount = savedAccount.flatMap(CodexAccountSlot.init(rawValue:))
        self.selectedAccount = restoredAccount.flatMap { accounts.contains($0) ? $0 : nil } ?? .primary
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        for account in accounts where !account.isPrimary && CodexAccountProfile.hasStoredCredentials(for: account) {
            accountStatuses[account] = .stored
        }
        createWindow()

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
        orbView.onRefresh = { [weak self] in
            self?.orbView.state = .loading
            self?.client?.refresh()
        }
        orbView.onQuit = { NSApp.terminate(nil) }
        orbView.onPositionChanged = { [weak self] in self?.saveWindowPosition() }
        orbView.onSelectAccount = { [weak self] account in self?.switchAccount(to: account) }
        orbView.onAddAccount = { [weak self] in self?.addAccount() }
        orbView.onLoginAccount = { [weak self] account in self?.loginAccount(account) }
        orbView.onDeleteAccount = { [weak self] account in self?.deleteAccount(account) }
        updateAccountMenuState()
        window.contentView = orbView
    }

    private func startOrb() {
        window.orderFrontRegardless()
        guard client == nil else { return }

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
        client.onSnapshot = { [weak self, weak client] snapshot in
            guard let self, self.client === client else { return }
            self.orbView.state = .loaded(snapshot)
        }
        client.onAccount = { [weak self, weak client] account in
            guard let self, self.client === client else { return }
            self.accountStatuses[clientAccount] = account.map(CodexAccountStatus.signedIn) ?? .signedOut
            self.updateAccountMenuState()
            if account == nil {
                let name = self.accountName(for: clientAccount)
                self.orbView.state = .failed("\(name)未登录，请右键登录")
            }
        }
        client.onLoginURL = { [weak self, weak client] url in
            guard let self, self.client === client else { return }
            NSApp.activate(ignoringOtherApps: true)
            if !NSWorkspace.shared.open(url) {
                self.orbView.state = .failed("无法打开 ChatGPT 登录页面")
            }
        }
        client.onError = { [weak self, weak client] error in
            guard let self, self.client === client else { return }
            self.orbView.state = .failed(error.localizedDescription)
        }
        self.client = client
        client.start()
        if pendingAccountLogin == clientAccount {
            pendingAccountLogin = nil
            let replacingExisting = pendingLoginReplacesExisting
            pendingLoginReplacesExisting = false
            client.loginWithChatGPT(replacingExisting: replacingExisting)
        }

        let timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            self?.client?.refresh()
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopOrb(hideWindow: Bool = true) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        client?.stop()
        client = nil
        if hideWindow {
            window.orderOut(nil)
        }
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
        guard accounts.contains(account), !account.isPrimary else { return }
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

    private func deleteAccount(_ account: CodexAccountSlot) {
        guard accounts.contains(account), !account.isPrimary else { return }
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
                selectedAccount = .primary
                UserDefaults.standard.set(CodexAccountSlot.primary.rawValue, forKey: Self.selectedAccountDefaultsKey)
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
    }

    private func accountName(for account: CodexAccountSlot) -> String {
        if account.isPrimary { return "当前 Codex 账号" }
        if case .signedIn(let summary) = accountStatuses[account], let email = summary.email {
            return email
        }
        let index = accounts.filter { !$0.isPrimary }.firstIndex(of: account).map { $0 + 1 } ?? 1
        return "额度账号 \(index)"
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
        if codexGUIRunning || codexCLIRunning {
            startOrb()
        } else {
            stopOrb()
        }
    }

    private func application(from notification: Notification) -> NSRunningApplication? {
        notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    private func restoredOrDefaultOrigin() -> NSPoint {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "orb.x") != nil,
           defaults.object(forKey: "orb.y") != nil {
            let point = NSPoint(
                x: defaults.double(forKey: "orb.x"),
                y: defaults.double(forKey: "orb.y")
            )
            let savedFrame = NSRect(origin: point, size: orbSize)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(savedFrame) }) {
                return point
            }
        }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        return NSPoint(x: visible.maxX - orbSize.width - 24, y: visible.minY + 36)
    }

    private func saveWindowPosition() {
        UserDefaults.standard.set(window.frame.origin.x, forKey: "orb.x")
        UserDefaults.standard.set(window.frame.origin.y, forKey: "orb.y")
    }
}
