import AppKit
import QuotaCore

enum QuotaProvider: String, CaseIterable {
    case codex, gemini, claudeCode, openCodeGo, kimiCode

    var title: String {
        switch self {
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .claudeCode: return "Claude Code"
        case .openCodeGo: return "OpenCode Go"
        case .kimiCode: return "Kimi Code"
        }
    }

    var supportsMonthlyQuota: Bool { self == .openCodeGo || self == .kimiCode }
}

final class QuotaOrbView: NSView {
    private static let designDiameter: CGFloat = 148
    private static let displayedWindowDefaultsKey = "quota.displayedWindow"
    private let defaults: UserDefaults
    private struct QuotaContext: Hashable {
        let provider: QuotaProvider
        let account: CodexAccountSlot?
    }
    private var recentQuotas: [QuotaContext: QuotaSnapshot] = [:]

    private enum DisplayedWindow: String, CaseIterable {
        case fiveHour
        case weekly
        case monthly

        var title: String {
            switch self {
            case .fiveHour: return "5 小时"
            case .weekly: return "本周"
            case .monthly: return "本月"
            }
        }

        func quota(in snapshot: QuotaSnapshot) -> QuotaWindow? {
            switch self {
            case .fiveHour: return snapshot.fiveHour
            case .weekly: return snapshot.weekly
            case .monthly: return snapshot.monthly
            }
        }
    }

    var state: QuotaDisplayState = .loading {
        didSet {
            if case .loaded(let snapshot) = state, provider != .codex || selectedAccount != nil {
                recentQuotas[quotaContext(for: provider)] = snapshot
            }
            needsDisplay = true
            updateAccessibility()
        }
    }
    var provider: QuotaProvider = .codex {
        didSet {
            if provider != oldValue { state = .loading }
        }
    }
    var onRefresh: (() -> Void)?
    var refreshCadence: QuotaRefreshCadence = .thirtySeconds
    var onSelectRefreshCadence: ((QuotaRefreshCadence) -> Void)?
    var onQuit: (() -> Void)?
    var onPositionChanged: (() -> Void)?
    var onResetPosition: (() -> Void)?
    var sizePreference: OrbSizePreference = .standard
    var onSelectSize: ((OrbSizePreference) -> Void)?
    var resetDisplay: OrbResetDisplay = .time {
        didSet { needsDisplay = true }
    }
    var onSelectResetDisplay: ((OrbResetDisplay) -> Void)?
    var showsMenuBarQuota = false
    var menuBarOnly = false
    var staysOnTop = true
    var onToggleMenuBarQuota: (() -> Void)?
    var onToggleWindowLevel: (() -> Void)?
    var onRaiseOrb: (() -> Void)?
    var onToggleOrbVisibility: (() -> Void)?
    var onPresentationChanged: (() -> Void)?
    var onSelectProvider: ((QuotaProvider) -> Void)?
    var onSelectAccount: ((CodexAccountSlot) -> Void)?
    var onAddAccount: (() -> Void)?
    var onLoginAccount: ((CodexAccountSlot) -> Void)?
    var onRenameAccount: ((CodexAccountSlot) -> Void)?
    var onDeleteAccount: ((CodexAccountSlot) -> Void)?
    var onConfigureOpenCodeGo: (() -> Void)?
    var accounts: [CodexAccountSlot] = []
    var codexMeteredQuotas: [CodexMeteredQuota] = []
    var selectedAccount: CodexAccountSlot?
    var accountStatuses: [CodexAccountSlot: CodexAccountStatus] = [:]
    var accountNames: [CodexAccountSlot: String] = [:]
    var quitMenuTitle = "退出额度悬浮球"

    private var mouseDownLocation: NSPoint?
    private var windowOriginAtMouseDown: NSPoint?
    private var dragged = false
    private var windowPreferenceKey: String {
        "\(Self.displayedWindowDefaultsKey).\(provider.rawValue)"
    }
    private var displayedWindow: DisplayedWindow {
        let saved = defaults.string(forKey: windowPreferenceKey)
            ?? defaults.string(forKey: Self.displayedWindowDefaultsKey)
        return saved.flatMap(DisplayedWindow.init(rawValue:)) ?? .weekly
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(frame frameRect: NSRect, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = min(bounds.width, bounds.height) / Self.designDiameter
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        defer { context.restoreGState() }

        let designBounds = NSRect(
            x: 0,
            y: 0,
            width: Self.designDiameter,
            height: Self.designDiameter
        )
        let circle = designBounds.insetBy(dx: 8, dy: 8)
        let path = NSBezierPath(ovalIn: circle)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        NSColor.black.withAlphaComponent(0.2).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        let accent = accentColor
        let gradient = NSGradient(colors: [
            accent.blended(withFraction: 0.12, of: .white) ?? accent,
            accent.blended(withFraction: 0.28, of: .black) ?? accent,
        ])
        gradient?.draw(in: path, angle: -55)

        NSColor.white.withAlphaComponent(0.15).setStroke()
        path.lineWidth = 1
        path.stroke()

        drawProgressRing(in: circle)
        drawLabels()
    }

    private var accentColor: NSColor {
        if state.errorMessage != nil {
            return NSColor(calibratedRed: 0.36, green: 0.39, blue: 0.45, alpha: 1)
        }
        guard let snapshot = state.snapshot else {
            return NSColor(calibratedRed: 0.32, green: 0.37, blue: 0.48, alpha: 1)
        }
        let remaining = displayedQuota(in: snapshot)?.quota.remainingPercent ?? 0
        if remaining <= 20 {
            return NSColor(calibratedRed: 0.88, green: 0.25, blue: 0.28, alpha: 1)
        }
        if remaining <= 50 {
            return NSColor(calibratedRed: 0.94, green: 0.58, blue: 0.16, alpha: 1)
        }
        return NSColor(calibratedRed: 0.12, green: 0.66, blue: 0.55, alpha: 1)
    }

    private func drawProgressRing(in circle: NSRect) {
        let ringRect = circle.insetBy(dx: 6, dy: 6)
        let background = NSBezierPath(ovalIn: ringRect)
        background.lineWidth = 5
        NSColor.white.withAlphaComponent(0.18).setStroke()
        background.stroke()

        guard let snapshot = state.snapshot, let displayed = displayedQuota(in: snapshot) else { return }
        let center = NSPoint(x: ringRect.midX, y: ringRect.midY)
        let progress = NSBezierPath()
        progress.appendArc(
            withCenter: center,
            radius: ringRect.width / 2,
            startAngle: 90,
            endAngle: 90 - CGFloat(displayed.quota.remainingPercent) * 3.6,
            clockwise: true
        )
        progress.lineWidth = 5
        progress.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.92).setStroke()
        progress.stroke()
    }

    private func drawLabels() {
        switch state {
        case .loading:
            drawCentered("正在同步", y: 34, font: .systemFont(ofSize: 12, weight: .medium), alpha: 0.82)
            drawCentered("•••", y: 53, font: .systemFont(ofSize: 30, weight: .bold), alpha: 1)
            drawCentered("连接 \(provider.title)", y: 99, font: .systemFont(ofSize: 11, weight: .medium), alpha: 0.78)
        case .failed:
            let title = provider == .codex ? "额度暂不可用" : "\(provider.title) 暂不可用"
            drawCentered(title, y: 34, font: .systemFont(ofSize: 12, weight: .medium), alpha: 0.82)
            drawCentered("—", y: 51, font: .systemFont(ofSize: 35, weight: .bold), alpha: 1)
            drawCentered("单击重试", y: 100, font: .systemFont(ofSize: 11, weight: .medium), alpha: 0.78)
        case .loaded(let snapshot), .refreshing(let snapshot), .stale(let snapshot, _):
            guard let displayed = displayedQuota(in: snapshot) else { return }
            let title: String
            if provider == .claudeCode {
                let status = state.errorMessage != nil ? "上次" : "缓存"
                title = "Claude · \(status)\(displayed.title)"
            } else if provider != .codex {
                let status = state.errorMessage != nil ? "上次\(displayed.title)" : displayed.title
                title = "\(provider.title) · \(status)"
            } else if state.errorMessage != nil {
                title = "上次\(displayed.title)额度"
            } else if state.isRefreshing {
                title = "\(displayed.title) · 同步中"
            } else {
                title = "\(displayed.title)额度"
            }
            drawCentered(
                title,
                y: 28,
                font: .systemFont(ofSize: 11, weight: .medium),
                alpha: 0.82
            )
            drawCentered(
                "\(displayed.quota.remainingPercent)%",
                y: 43,
                font: .monospacedDigitSystemFont(ofSize: 38, weight: .bold),
                alpha: 1
            )
            let reset = displayed.quota.resetsAt.map { date in
                resetDisplay == .countdown ? OrbResetDisplay.countdownLabel(to: date) : Self.shortDateFormatter.string(from: date)
            } ?? "时间未知"
            drawCentered(
                reset,
                y: 92,
                font: .monospacedDigitSystemFont(ofSize: 17, weight: .semibold),
                alpha: 0.94
            )
        }
    }

    private func drawCentered(_ text: String, y: CGFloat, font: NSFont, alpha: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            .paragraphStyle: paragraph,
        ]
        text.draw(
            in: NSRect(x: 15, y: y, width: Self.designDiameter - 30, height: font.pointSize + 6),
            withAttributes: attributes
        )
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = NSEvent.mouseLocation
        windowOriginAtMouseDown = window?.frame.origin
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation,
              let origin = windowOriginAtMouseDown,
              let window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - start.x
        let dy = current.y - start.y
        guard dragged || hypot(dx, dy) > 3 else { return }
        dragged = true
        window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownLocation != nil else { return }
        if dragged {
            onPositionChanged?()
        } else {
            onRefresh?()
        }
        mouseDownLocation = nil
        windowOriginAtMouseDown = nil
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onRefresh, !state.isRefreshing else { return false }
        onRefresh()
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard window?.isVisible == true else { return false }
        return makeMenu().popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        populateMenu(menu)
        return menu
    }

    func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.title = "\(provider.title) 额度"
        menu.autoenablesItems = false
        let refresh = NSMenuItem(title: "立即刷新", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = !state.isRefreshing
        menu.addItem(refresh)
        menu.addItem(refreshCadenceMenuItem())

        let copy = NSMenuItem(title: "复制额度摘要", action: #selector(copyQuotaSummary), keyEquivalent: "c")
        copy.target = self
        copy.isEnabled = state.snapshot != nil
        menu.addItem(copy)

        let sourceItem = NSMenuItem(title: "切换额度来源", action: nil, keyEquivalent: "")
        let sourceMenu = NSMenu(title: sourceItem.title)
        for source in QuotaProvider.allCases {
            let item = NSMenuItem(title: source.title, action: #selector(selectProvider(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = source.rawValue
            item.state = source == provider ? .on : .off
            sourceMenu.addItem(item)
        }
        sourceItem.submenu = sourceMenu
        menu.addItem(sourceItem)
        menu.addItem(recentQuotasMenuItem())
        if provider == .codex {
            menu.addItem(accountMenuItem())
        } else if provider == .openCodeGo {
            let configure = NSMenuItem(
                title: "设置 OpenCode Go API 密钥…", action: #selector(configureOpenCodeGo), keyEquivalent: ""
            )
            configure.target = self
            menu.addItem(configure)
        }
        menu.addItem(.separator())

        let loadedSnapshot = state.snapshot
        let effectiveWindow = loadedSnapshot.map(resolvedWindow) ?? displayedWindow

        for period in DisplayedWindow.allCases where period != .monthly || provider.supportsMonthlyQuota {
            let prefix = period == .fiveHour ? "展示 " : "展示"
            let item = NSMenuItem(
                title: "\(prefix)\(period.title)额度", action: #selector(selectDisplayedWindow(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = period.rawValue
            item.state = effectiveWindow == period ? .on : .off
            item.isEnabled = loadedSnapshot.flatMap { period.quota(in: $0) } != nil
            menu.addItem(item)
        }
        menu.addItem(.separator())

        if let snapshot = loadedSnapshot {
            for line in quotaDetails(in: snapshot) {
                let detail = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                detail.isEnabled = false
                menu.addItem(detail)
            }
            let updated = NSMenuItem(
                title: updatedDetail(for: snapshot),
                action: nil,
                keyEquivalent: ""
            )
            updated.isEnabled = false
            menu.addItem(updated)
            if provider == .codex, !codexMeteredQuotas.isEmpty {
                menu.addItem(meteredQuotasMenuItem())
            }
            menu.addItem(.separator())
        }
        if let message = state.errorMessage {
            let title = loadedSnapshot == nil ? message : "\(staleMenuLabel)：\(message)"
            let detail = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)
            menu.addItem(.separator())
        }

        menu.addItem(appearanceMenuItem())
        if showsMenuBarQuota {
            let title = menuBarOnly ? "显示悬浮球" : "仅在菜单栏显示"
            let visibility = NSMenuItem(title: title, action: #selector(toggleOrbVisibility), keyEquivalent: "")
            visibility.target = self
            menu.addItem(visibility)
            if !staysOnTop && !menuBarOnly {
                let raise = menu.addItem(withTitle: "将悬浮球移到前台", action: #selector(raiseOrb), keyEquivalent: "")
                raise.target = self
            }
        }
        let quit = NSMenuItem(title: quitMenuTitle, action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func quotaContext(for source: QuotaProvider) -> QuotaContext {
        QuotaContext(provider: source, account: source == .codex ? selectedAccount : nil)
    }

    func forgetQuota(for source: QuotaProvider, account: CodexAccountSlot? = nil) {
        recentQuotas.removeValue(forKey: QuotaContext(provider: source, account: account))
    }

    private func recentQuotasMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "最近读取的额度", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: item.title)
        submenu.autoenablesItems = false
        for source in QuotaProvider.allCases {
            guard let snapshot = recentQuotas[quotaContext(for: source)] else {
                let empty = submenu.addItem(withTitle: "\(source.title) · 尚无结果", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                continue
            }
            let entry = submenu.addItem(withTitle: source.title, action: nil, keyEquivalent: "")
            let details = NSMenu(title: source.title)
            for line in quotaDetails(in: snapshot) {
                details.addItem(withTitle: line, action: nil, keyEquivalent: "")
            }
            let time = Self.longDateFormatter.string(from: snapshot.fetchedAt)
            details.addItem(withTitle: "上次采集：\(time)", action: nil, keyEquivalent: "")
            entry.submenu = details
        }
        item.submenu = submenu
        return item
    }

    private func appearanceMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: item.title)
        submenu.addItem(orbSizeMenuItem())
        submenu.addItem(resetDisplayMenuItem())
        let pin = submenu.addItem(withTitle: "保持悬浮球置顶", action: #selector(toggleWindowLevel), keyEquivalent: "")
        pin.target = self
        pin.state = staysOnTop ? .on : .off
        let reset = submenu.addItem(withTitle: "重置悬浮球位置", action: #selector(resetPositionFromMenu), keyEquivalent: "")
        reset.target = self
        submenu.addItem(.separator())
        let menuBarToggle = submenu.addItem(withTitle: "在菜单栏显示额度", action: #selector(toggleMenuBarQuota), keyEquivalent: "")
        menuBarToggle.target = self
        menuBarToggle.state = showsMenuBarQuota ? .on : .off
        item.submenu = submenu
        return item
    }

    private func refreshCadenceMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "定时刷新", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: item.title)
        for cadence in QuotaRefreshCadence.allCases {
            let option = NSMenuItem(title: cadence.title, action: #selector(selectRefreshCadence(_:)), keyEquivalent: "")
            option.target = self
            option.tag = cadence.rawValue
            option.state = cadence == refreshCadence ? .on : .off
            submenu.addItem(option)
        }
        item.submenu = submenu
        return item
    }

    private func orbSizeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "悬浮球大小", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: item.title)
        for size in OrbSizePreference.allCases {
            let option = NSMenuItem(title: size.title, action: #selector(selectOrbSize(_:)), keyEquivalent: "")
            option.target = self
            option.tag = size.rawValue
            option.state = size == sizePreference ? .on : .off
            submenu.addItem(option)
        }
        item.submenu = submenu
        return item
    }

    private func resetDisplayMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "悬浮球时间显示", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: item.title)
        for mode in OrbResetDisplay.allCases {
            let option = NSMenuItem(title: mode.title, action: #selector(selectResetDisplay(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = mode.rawValue
            option.state = mode == resetDisplay ? .on : .off
            submenu.addItem(option)
        }
        item.submenu = submenu
        return item
    }

    private func accountMenuItem() -> NSMenuItem {
        let accountItem = NSMenuItem(title: "切换额度账号", action: nil, keyEquivalent: "")
        let accountMenu = NSMenu(title: "切换额度账号")
        for slot in accounts {
            let item = NSMenuItem(
                title: accountMenuTitle(for: slot),
                action: #selector(selectAccount(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = slot.rawValue
            item.state = selectedAccount == slot ? .on : .off
            accountMenu.addItem(item)
        }
        if accounts.isEmpty {
            let empty = NSMenuItem(title: "尚未添加账号", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            accountMenu.addItem(empty)
        }
        accountMenu.addItem(.separator())
        let addAccount = NSMenuItem(
            title: "新加额度账号…",
            action: #selector(addAccountFromMenu),
            keyEquivalent: ""
        )
        addAccount.target = self
        accountMenu.addItem(addAccount)

        if let selectedAccount,
           accountStatuses[selectedAccount] == .signedOut {
            let login = NSMenuItem(
                title: "登录当前额度账号…",
                action: #selector(loginCurrentAccountFromMenu),
                keyEquivalent: ""
            )
            login.target = self
            accountMenu.addItem(login)
        }

        if selectedAccount != nil {
            let rename = NSMenuItem(title: "重命名当前额度账号…", action: #selector(renameCurrentAccountFromMenu), keyEquivalent: "")
            rename.target = self
            accountMenu.addItem(rename)
        }

        if !accounts.isEmpty {
            let deleteItem = NSMenuItem(title: "删除额度账号", action: nil, keyEquivalent: "")
            let deleteMenu = NSMenu(title: "删除额度账号")
            for slot in accounts {
                let item = NSMenuItem(
                    title: accountMenuTitle(for: slot),
                    action: #selector(deleteAccountFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = slot.rawValue
                deleteMenu.addItem(item)
            }
            deleteItem.submenu = deleteMenu
            accountMenu.addItem(deleteItem)
        }
        accountItem.submenu = accountMenu
        return accountItem
    }

    private func meteredQuotasMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "其他 Codex 额度", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: item.title)
        submenu.autoenablesItems = false
        for bucket in codexMeteredQuotas {
            let heading = NSMenuItem(title: bucket.name, action: nil, keyEquivalent: "")
            heading.isEnabled = false
            submenu.addItem(heading)
            for line in quotaDetails(in: bucket.snapshot) {
                let detail = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                detail.isEnabled = false
                detail.indentationLevel = 1
                submenu.addItem(detail)
            }
        }
        item.submenu = submenu
        return item
    }

    @objc private func refreshFromMenu() { onRefresh?() }
    @objc private func quitFromMenu() { onQuit?() }
    @objc private func resetPositionFromMenu() { onResetPosition?() }
    @objc private func toggleMenuBarQuota() { onToggleMenuBarQuota?() }
    @objc private func toggleOrbVisibility() { onToggleOrbVisibility?() }
    @objc private func toggleWindowLevel() { onToggleWindowLevel?() }
    @objc private func raiseOrb() { onRaiseOrb?() }

    @objc private func selectOrbSize(_ sender: NSMenuItem) {
        guard let size = OrbSizePreference(rawValue: sender.tag) else { return }
        onSelectSize?(size)
    }

    @objc private func selectResetDisplay(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String, let mode = OrbResetDisplay(rawValue: rawValue) else { return }
        onSelectResetDisplay?(mode)
    }

    @objc private func selectRefreshCadence(_ sender: NSMenuItem) {
        guard let cadence = QuotaRefreshCadence(rawValue: sender.tag) else { return }
        onSelectRefreshCadence?(cadence)
    }

    @objc private func copyQuotaSummary() {
        guard let quotaSummary else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(quotaSummary, forType: .string)
    }

    var quotaSummary: String? {
        guard let snapshot = state.snapshot else { return nil }
        var lines = ["\(provider.title) 额度"] + quotaDetails(in: snapshot) + [updatedDetail(for: snapshot)]
        if state.errorMessage != nil {
            lines.append(staleMenuLabel)
        } else if state.isRefreshing {
            lines.append("正在刷新，显示上次数据")
        }
        return lines.joined(separator: "\n")
    }

    private func quotaDetails(in snapshot: QuotaSnapshot) -> [String] {
        DisplayedWindow.allCases.compactMap { period in
            guard let quota = period.quota(in: snapshot) else { return nil }
            let reset = quota.resetsAt.map { "\(Self.longDateFormatter.string(from: $0)) 重置" } ?? "重置时间未知"
            return "\(period.title)额度：剩余 \(quota.remainingPercent)% · \(reset)"
        }
    }

    private func updatedDetail(for snapshot: QuotaSnapshot) -> String {
        "\(lastUpdatedLabel)：\(Self.longDateFormatter.string(from: snapshot.fetchedAt))"
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let provider = QuotaProvider(rawValue: rawValue) else { return }
        onSelectProvider?(provider)
    }

    @objc private func selectAccount(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let account = CodexAccountSlot(rawValue: rawValue) else { return }
        onSelectAccount?(account)
    }

    @objc private func addAccountFromMenu() { onAddAccount?() }

    @objc private func loginCurrentAccountFromMenu() {
        guard let selectedAccount else { return }
        onLoginAccount?(selectedAccount)
    }

    @objc private func renameCurrentAccountFromMenu() {
        guard let selectedAccount else { return }
        onRenameAccount?(selectedAccount)
    }

    @objc private func deleteAccountFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let account = CodexAccountSlot(rawValue: rawValue) else { return }
        onDeleteAccount?(account)
    }

    @objc private func selectDisplayedWindow(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let selected = DisplayedWindow(rawValue: rawValue) else { return }
        defaults.set(selected.rawValue, forKey: windowPreferenceKey)
        needsDisplay = true
        updateAccessibility()
    }

    @objc private func configureOpenCodeGo() {
        onConfigureOpenCodeGo?()
    }

    /// Falls back to whichever window the current plan actually publishes.
    private func resolvedWindow(in snapshot: QuotaSnapshot) -> DisplayedWindow {
        let preferred = displayedWindow
        if preferred.quota(in: snapshot) != nil { return preferred }
        return [DisplayedWindow.weekly, .fiveHour, .monthly].first { $0.quota(in: snapshot) != nil } ?? preferred
    }

    private func displayedQuota(in snapshot: QuotaSnapshot) -> (title: String, quota: QuotaWindow)? {
        let period = resolvedWindow(in: snapshot)
        return period.quota(in: snapshot).map { (period.title, $0) }
    }

    var menuBarTitle: String {
        let percent = state.snapshot.flatMap(displayedQuota).map { "\($0.quota.remainingPercent)%" }
        switch state {
        case .loading: return "额度…"
        case .failed: return "额度 —"
        case .loaded: return percent ?? "额度"
        case .refreshing: return percent.map { "\($0)…" } ?? "额度…"
        case .stale: return percent.map { "~\($0)" } ?? "额度 —"
        }
    }

    private var lastUpdatedLabel: String { provider == .claudeCode ? "状态栏采集时间" : "最后更新" }
    private var staleMenuLabel: String { provider == .claudeCode ? "显示上次缓存" : "刷新失败（显示上次数据）" }

    private func accountMenuTitle(for slot: CodexAccountSlot) -> String {
        let title = accountDisplayName(for: slot)
        switch accountStatuses[slot] ?? .unknown {
        case .unknown:
            return title
        case .stored:
            return "\(title) · 已保存"
        case .signedOut:
            return "\(title) · 未登录"
        case .signedIn(let account):
            let identity = account.email ?? "ChatGPT"
            let plan = account.planType.map { " · \($0.uppercased())" } ?? ""
            return "\(title) · \(identity)\(plan)"
        }
    }

    private func accountDisplayName(for slot: CodexAccountSlot) -> String {
        if let name = accountNames[slot] { return name }
        let index = accounts.firstIndex(of: slot).map { $0 + 1 } ?? 1
        return "额度账号 \(index)"
    }

    private func updateAccessibility() {
        var description: String
        switch state {
        case .loading:
            description = "\(provider.title) 额度正在同步"
        case .failed(let message):
            description = "\(provider.title) 额度不可用，\(message)"
        case .loaded(let snapshot), .refreshing(let snapshot), .stale(let snapshot, _):
            if let displayed = displayedQuota(in: snapshot) {
                let reset = displayed.quota.resetsAt.map(Self.longDateFormatter.string) ?? "未知时间"
                description = "\(provider.title) \(displayed.title)额度剩余 \(displayed.quota.remainingPercent)%，\(reset) 重置"
            } else {
                description = "\(provider.title) 额度已同步"
            }
            description += "；\(lastUpdatedLabel)：\(Self.longDateFormatter.string(from: snapshot.fetchedAt))"
            if let message = state.errorMessage {
                let status = provider == .claudeCode ? "显示上次缓存" : "刷新失败，显示上次数据"
                description += "；\(status)：\(message)"
            } else if state.isRefreshing {
                description += "；正在刷新，显示上次数据"
            }
        }
        toolTip = description
        setAccessibilityLabel(description)
        setAccessibilityHelp("可拖动悬浮球，单击刷新，右键切换额度来源或周期")
        onPresentationChanged?()
    }

    func refreshLocalTimeFormatting() {
        Self.shortDateFormatter.timeZone = .current
        Self.longDateFormatter.timeZone = .current
        needsDisplay = true
        updateAccessibility()
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter
    }()

    private static let longDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
