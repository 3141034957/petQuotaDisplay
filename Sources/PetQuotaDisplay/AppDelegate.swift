import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let codexBundleIdentifier = "com.openai.codex"
    private static let selectedAccountDefaultsKey = "quota.selectedAccount"

    private let orbSize = NSSize(width: 74, height: 74)
    private let followCodex: Bool
    private var client: CodexQuotaClient?
    private var window: NSWindow!
    private var orbView: QuotaOrbView!
    private var refreshTimer: Timer?
    private var cliMonitor: CodexCLIProcessMonitor?
    private var codexGUIRunning = false
    private var codexCLIRunning = false
    private var selectedAccount: CodexAccountSlot
    private var accountStatuses: [CodexAccountSlot: CodexAccountStatus] = [:]
    private var pendingSecondaryLogin: Bool?

    init(followCodex: Bool) {
        self.followCodex = followCodex
        let savedAccount = UserDefaults.standard.string(forKey: Self.selectedAccountDefaultsKey)
        self.selectedAccount = savedAccount.flatMap(CodexAccountSlot.init(rawValue:)) ?? .primary
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CodexAccountProfile.hasStoredCredentials(for: .secondary) {
            accountStatuses[.secondary] = .stored
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
        orbView.onConfigureSecondaryAccount = { [weak self] in self?.configureSecondaryAccount() }
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
            orbView.state = .failed("无法创建备用账号目录：\(error.localizedDescription)")
            return
        }

        orbView.state = .loading
        let client = CodexQuotaClient(codexHome: codexHome)
        client.onSnapshot = { [weak self, weak client] snapshot in
            guard let self, self.client === client else { return }
            self.orbView.state = .loaded(snapshot)
        }
        client.onAccount = { [weak self, weak client] account in
            guard let self, self.client === client else { return }
            self.accountStatuses[self.selectedAccount] = account.map(CodexAccountStatus.signedIn) ?? .signedOut
            self.updateAccountMenuState()
            if account == nil {
                let name = self.selectedAccount == .secondary ? "备用账号" : "当前 Codex 账号"
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
        if let replacingExisting = pendingSecondaryLogin {
            pendingSecondaryLogin = nil
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
        guard account != selectedAccount else { return }
        selectedAccount = account
        UserDefaults.standard.set(account.rawValue, forKey: Self.selectedAccountDefaultsKey)
        updateAccountMenuState()
        stopOrb(hideWindow: false)
        startOrb()
    }

    private func configureSecondaryAccount() {
        let hasExistingAccount: Bool
        switch accountStatuses[.secondary] ?? .unknown {
        case .stored, .signedIn:
            hasExistingAccount = true
        case .unknown, .signedOut:
            hasExistingAccount = CodexAccountProfile.hasStoredCredentials(for: .secondary)
        }

        if hasExistingAccount {
            let alert = NSAlert()
            alert.messageText = "更换备用账号？"
            alert.informativeText = "这会清除额度悬浮球保存的备用账号登录状态，然后打开 ChatGPT 登录页。当前 Codex 账号不会受影响。"
            alert.addButton(withTitle: "更换账号")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        pendingSecondaryLogin = hasExistingAccount
        if selectedAccount == .secondary {
            let replacingExisting = pendingSecondaryLogin ?? false
            pendingSecondaryLogin = nil
            orbView.state = .loading
            client?.loginWithChatGPT(replacingExisting: replacingExisting)
        } else {
            switchAccount(to: .secondary)
        }
    }

    private func updateAccountMenuState() {
        guard orbView != nil else { return }
        orbView.selectedAccount = selectedAccount
        orbView.accountStatuses = accountStatuses
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
