import AppKit
import QuotaCore

final class QuotaOrbView: NSView {
    private static let designDiameter: CGFloat = 148
    private let defaults: UserDefaults
    private var recentQuotas: [QuotaHistoryContext: QuotaReadingHistory] = [:]

    var state: QuotaDisplayState = .loading {
        didSet {
            if case .loaded(let snapshot) = state, provider != .codex || selectedAccount != nil {
                let context = quotaContext(for: provider)
                let previous = recentQuotas[context]?.latest
                recentQuotas[context, default: QuotaReadingHistory()].record(snapshot)
                if let current = recentQuotas[context], current.latest != previous {
                    onQuotaHistoryChanged?(context, current.readings)
                }
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
    var onShowQuotaHistory: ((QuotaHistoryContext, [QuotaSnapshot]) -> Void)?
    var onQuotaHistoryChanged: ((QuotaHistoryContext, [QuotaSnapshot]) -> Void)?
    var onQuotaHistoryCleared: (() -> Void)?
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
    var onCancelLogin: (() -> Void)?
    var onRenameAccount: ((CodexAccountSlot) -> Void)?
    var onDeleteAccount: ((CodexAccountSlot) -> Void)?
    var onConfigureOpenCodeGo: (() -> Void)?
    var accounts: [CodexAccountSlot] = []
    var codexMeteredQuotas: [CodexMeteredQuota] = []
    var selectedAccount: CodexAccountSlot?
    var accountStatuses: [CodexAccountSlot: CodexAccountStatus] = [:]
    var isCodexLoginPending = false {
        didSet {
            needsDisplay = true
            updateAccessibility()
        }
    }
    var accountNames: [CodexAccountSlot: String] = [:]
    var quitMenuTitle = "退出额度悬浮球"

    private var mouseDownLocation: NSPoint?
    private var windowOriginAtMouseDown: NSPoint?
    private var dragged = false
    private var windowPreferenceKey: String {
        QuotaWindowPreference.key(for: provider, account: selectedAccount)
    }
    var startupPeriodOverride: String?
    private var windowPreferenceValue: String? {
        startupPeriodOverride ?? defaults.string(forKey: windowPreferenceKey)
            ?? defaults.string(forKey: QuotaWindowPreference.key(for: provider))
            ?? defaults.string(forKey: QuotaWindowPreference.legacyKey)
    }
    private var displayedWindow: QuotaPeriod {
        windowPreferenceValue.flatMap(QuotaPeriod.init(rawValue:)) ?? .weekly
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(frame frameRect: NSRect, defaults: UserDefaults = QuotaPreferences.shared) {
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

        guard let snapshot = state.snapshot, let displayed = displayedQuota(in: snapshot),
              let progress = Self.progressPath(remainingPercent: displayed.quota.remainingPercent, in: ringRect) else { return }
        progress.lineWidth = 5
        progress.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.92).setStroke()
        progress.stroke()
    }

    static func progressPath(remainingPercent: Int, in rect: NSRect) -> NSBezierPath? {
        guard remainingPercent > 0 else { return nil }
        if remainingPercent >= 100 { return NSBezierPath(ovalIn: rect) }
        let progress = NSBezierPath()
        progress.appendArc(
            withCenter: NSPoint(x: rect.midX, y: rect.midY),
            radius: rect.width / 2,
            startAngle: -90,
            endAngle: -90 + CGFloat(remainingPercent) * 3.6,
            clockwise: false
        )
        return progress
    }

    private func drawLabels() {
        switch state {
        case .loading:
            let title = isCodexLoginPending ? "等待登录" : "正在同步"
            let detail = isCodexLoginPending ? "请在浏览器继续" : "连接 \(provider.title)"
            drawCentered(title, y: 34, font: .systemFont(ofSize: 12, weight: .medium), alpha: 0.82)
            drawCentered("•••", y: 53, font: .systemFont(ofSize: 30, weight: .bold), alpha: 1)
            drawCentered(detail, y: 99, font: .systemFont(ofSize: 11, weight: .medium), alpha: 0.78)
        case .failed:
            let title = provider == .codex ? "额度暂不可用" : "\(provider.title) 暂不可用"
            drawCentered(title, y: 34, font: .systemFont(ofSize: 12, weight: .medium), alpha: 0.82)
            drawCentered("—", y: 51, font: .systemFont(ofSize: 35, weight: .bold), alpha: 1)
            drawCentered("单击重试", y: 100, font: .systemFont(ofSize: 11, weight: .medium), alpha: 0.78)
        case .loaded(let snapshot), .refreshing(let snapshot), .stale(let snapshot, _):
            guard let displayed = displayedQuota(in: snapshot) else { return }
            let title: String
            if let model = displayedCodexBucket {
                let period = state.errorMessage == nil ? displayed.title : "上次\(displayed.title)"
                title = "\(model.name) · \(period)"
            } else if provider == .claudeCode {
                let status = state.errorMessage != nil ? "上次" : "缓存"
                title = "Claude · \(status)\(displayed.title)"
            } else if provider != .codex {
                let status: String
                if state.errorMessage != nil {
                    status = "上次\(displayed.title)"
                } else if state.isRefreshing {
                    status = "同步中"
                } else {
                    status = displayed.title
                }
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
        let lineWidth = Self.designDiameter - 30
        let textWidth = text.size(withAttributes: [.font: font]).width
        let fittedSize = textWidth > lineWidth ? max(font.pointSize * 0.8, font.pointSize * lineWidth / textWidth) : font.pointSize
        let fittedFont = fittedSize == font.pointSize ? font : NSFont(descriptor: font.fontDescriptor, size: fittedSize) ?? font
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: fittedFont,
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            .paragraphStyle: paragraph,
        ]
        text.draw(
            in: NSRect(x: 15, y: y + (font.pointSize - fittedFont.pointSize) / 2, width: lineWidth, height: font.pointSize + 6),
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
        menu.title = "\(displaySourceTitle) 额度"
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
        let json = menu.addItem(withTitle: "复制额度 JSON", action: #selector(copyQuotaJSON), keyEquivalent: "")
        json.target = self
        json.isEnabled = state.snapshot != nil

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

        let loadedSnapshot = state.snapshot.map(displaySnapshot)
        let effectiveWindow = loadedSnapshot.map(resolvedWindow) ?? displayedWindow
        let isAutomatic = windowPreferenceValue == QuotaWindowPreference.lowestRemaining
        let automatic = menu.addItem(
            withTitle: "自动展示剩余最少的周期", action: #selector(selectAdaptiveWindow), keyEquivalent: ""
        )
        automatic.target = self
        automatic.state = isAutomatic ? .on : .off

        for period in QuotaPeriod.allCases where period != .monthly || provider.supportsMonthlyQuota {
            let prefix = period == .fiveHour ? "展示 " : "展示"
            let item = NSMenuItem(
                title: "\(prefix)\(period.title)额度", action: #selector(selectDisplayedWindow(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = period.rawValue
            if effectiveWindow == period {
                item.state = isAutomatic ? .mixed : .on
            }
            item.isEnabled = loadedSnapshot?[period] != nil
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
        } else if loadedSnapshot != nil, state.isRefreshing {
            let status = menu.addItem(withTitle: "正在刷新，显示上次数据", action: nil, keyEquivalent: "")
            status.isEnabled = false
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

    private func quotaContext(for source: QuotaProvider) -> QuotaHistoryContext {
        QuotaHistoryContext(provider: source, account: source == .codex ? selectedAccount : nil)
    }

    func forgetQuota(for source: QuotaProvider, account: CodexAccountSlot? = nil) {
        let context = QuotaHistoryContext(provider: source, account: account)
        if recentQuotas.removeValue(forKey: context) != nil {
            onQuotaHistoryChanged?(context, [])
        }
    }

    func beginPollingWithRecentQuota() {
        let previous = recentQuotas[quotaContext(for: provider)]?.latest
        state = previous.map(QuotaDisplayState.refreshing) ?? .loading
    }

    private func recentQuotasMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "最近读取的额度", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: item.title)
        submenu.autoenablesItems = false
        let copy = submenu.addItem(withTitle: "复制最近额度总览", action: #selector(copyRecentQuotaSummary), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = recentQuotaSummary != nil
        let clear = submenu.addItem(withTitle: "清空最近额度记录", action: #selector(clearRecentQuotas), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !recentQuotas.isEmpty
        submenu.addItem(.separator())
        for source in QuotaProvider.allCases {
            let lines = recentQuotaDetails(for: source)
            guard !lines.isEmpty else {
                let empty = submenu.addItem(withTitle: "\(source.title) · 尚无结果", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                continue
            }
            let entry = submenu.addItem(withTitle: source.title, action: nil, keyEquivalent: "")
            let details = NSMenu(title: source.title)
            for line in lines {
                details.addItem(withTitle: line, action: nil, keyEquivalent: "")
            }
            if let history = recentQuotas[quotaContext(for: source)], history.readings.count > 1 {
                details.addItem(.separator())
                details.addItem(readingListMenuItem(history.readings))
                let trend = details.addItem(withTitle: "查看额度趋势…", action: #selector(showQuotaHistory(_:)), keyEquivalent: "")
                trend.target = self
                trend.representedObject = source.rawValue
            }
            entry.submenu = details
        }
        item.submenu = submenu
        return item
    }

    private func readingListMenuItem(_ readings: [QuotaSnapshot]) -> NSMenuItem {
        let item = NSMenuItem(title: "最近采集记录", action: nil, keyEquivalent: "")
        let list = NSMenu(title: item.title)
        for snapshot in readings.suffix(8).reversed() {
            let timestamp = Self.longDateFormatter.string(from: snapshot.fetchedAt)
            let quotas = QuotaPeriod.allCases.compactMap { period in
                snapshot[period].map { "\(period.title) \($0.remainingPercent)%" }
            }
            list.addItem(withTitle: ([timestamp] + quotas).joined(separator: " · "), action: nil, keyEquivalent: "")
        }
        item.submenu = list
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

        if isCodexLoginPending {
            let cancel = accountMenu.addItem(withTitle: "取消当前登录", action: #selector(cancelLoginFromMenu), keyEquivalent: "")
            cancel.target = self
        } else if let selectedAccount, accountStatuses[selectedAccount] == .signedOut {
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
        let item = NSMenuItem(title: "选择 Codex 额度", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: item.title)
        submenu.autoenablesItems = false
        let primary = submenu.addItem(withTitle: "主要额度", action: #selector(selectCodexBucket(_:)), keyEquivalent: "")
        primary.target = self
        primary.state = displayedCodexBucket == nil ? .on : .off
        submenu.addItem(.separator())
        for bucket in codexMeteredQuotas {
            let heading = submenu.addItem(withTitle: bucket.name, action: #selector(selectCodexBucket(_:)), keyEquivalent: "")
            heading.target = self
            heading.representedObject = bucket.id
            heading.state = displayedCodexBucket?.id == bucket.id ? .on : .off
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
        QuotaClipboard.copy(quotaSummary)
    }

    @objc private func copyQuotaJSON() {
        QuotaClipboard.copy(quotaJSON)
    }

    var quotaJSON: String? {
        try? QuotaExport(provider: provider, state: state, model: displayedCodexBucket)?.json()
    }

    @objc private func copyRecentQuotaSummary() {
        QuotaClipboard.copy(recentQuotaSummary)
    }

    @objc private func clearRecentQuotas() {
        recentQuotas.removeAll()
        onQuotaHistoryCleared?()
    }

    @objc private func showQuotaHistory(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let source = QuotaProvider(rawValue: rawValue) else { return }
        let context = quotaContext(for: source)
        guard let history = recentQuotas[context] else { return }
        onShowQuotaHistory?(context, history.readings)
    }

    var recentQuotaSummary: String? {
        let groups = QuotaProvider.allCases.compactMap { source -> String? in
            let lines = recentQuotaDetails(for: source)
            return lines.isEmpty ? nil : ([source.title] + lines).joined(separator: "\n")
        }
        guard !groups.isEmpty else { return nil }
        return (["最近读取的额度"] + groups).joined(separator: "\n\n")
    }

    private func recentQuotaDetails(for source: QuotaProvider) -> [String] {
        guard let history = recentQuotas[quotaContext(for: source)], let snapshot = history.latest else { return [] }
        var lines = quotaDetails(in: snapshot)
        for period in QuotaPeriod.allCases {
            switch history.change(in: period) {
            case .remainingPercentagePoints(let delta):
                let direction = delta < 0 ? "减少" : "增加"
                lines.append("\(period.title)剩余额度较上次\(direction) \(abs(delta)) 个百分点")
            case .resetTimeChanged:
                lines.append("\(period.title)额度的重置时间有变化")
            case nil: break
            }
        }
        lines.append("上次采集：\(Self.longDateFormatter.string(from: snapshot.fetchedAt))")
        return lines
    }

    var quotaSummary: String? {
        guard let snapshot = state.snapshot.map(displaySnapshot) else { return nil }
        var lines = ["\(displaySourceTitle) 额度"] + quotaDetails(in: snapshot) + [updatedDetail(for: snapshot)]
        if state.errorMessage != nil {
            lines.append(staleMenuLabel)
        } else if state.isRefreshing {
            lines.append("正在刷新，显示上次数据")
        }
        return lines.joined(separator: "\n")
    }

    private func quotaDetails(in snapshot: QuotaSnapshot) -> [String] {
        QuotaPeriod.allCases.compactMap { period in
            guard let quota = snapshot[period] else { return nil }
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
    @objc private func cancelLoginFromMenu() { onCancelLogin?() }

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
              let selected = QuotaPeriod(rawValue: rawValue) else { return }
        saveWindowPreference(selected.rawValue)
    }

    @objc private func selectAdaptiveWindow() {
        saveWindowPreference(QuotaWindowPreference.lowestRemaining)
    }

    private func saveWindowPreference(_ value: String) {
        startupPeriodOverride = nil
        defaults.set(value, forKey: windowPreferenceKey)
        needsDisplay = true
        updateAccessibility()
    }

    @objc private func configureOpenCodeGo() {
        onConfigureOpenCodeGo?()
    }

    /// Falls back to whichever window the current plan actually publishes.
    private func resolvedWindow(in snapshot: QuotaSnapshot) -> QuotaPeriod {
        if windowPreferenceValue == QuotaWindowPreference.lowestRemaining {
            return QuotaWindowPreference.lowestPeriod { snapshot[$0]?.remainingPercent } ?? .weekly
        }
        let preferred = displayedWindow
        if snapshot[preferred] != nil { return preferred }
        return QuotaWindowPreference.presentationOrder.first { snapshot[$0] != nil } ?? preferred
    }

    private func displayedQuota(in snapshot: QuotaSnapshot) -> (title: String, quota: QuotaWindow)? {
        let snapshot = displaySnapshot(snapshot)
        let period = resolvedWindow(in: snapshot)
        return snapshot[period].map { (period.title, $0) }
    }

    private var displayedCodexBucket: CodexMeteredQuota? {
        guard provider == .codex, state.snapshot != nil, let selectedAccount,
              let id = defaults.string(forKey: CodexAccountProfile.limitPreferenceKey(for: selectedAccount)) else { return nil }
        return codexMeteredQuotas.first { $0.id == id }
    }

    private var displaySourceTitle: String {
        displayedCodexBucket.map { "Codex · \($0.name)" } ?? provider.title
    }

    private func displaySnapshot(_ primary: QuotaSnapshot) -> QuotaSnapshot {
        displayedCodexBucket?.snapshot ?? primary
    }

    @objc private func selectCodexBucket(_ sender: NSMenuItem) {
        guard provider == .codex, let selectedAccount else { return }
        let key = CodexAccountProfile.limitPreferenceKey(for: selectedAccount)
        if let id = sender.representedObject as? String {
            defaults.set(id, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        needsDisplay = true
        updateAccessibility()
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
            description = isCodexLoginPending ? "请在浏览器完成 Codex 额度账号登录" : "\(provider.title) 额度正在同步"
        case .failed(let message):
            description = "\(provider.title) 额度不可用，\(message)"
        case .loaded(let snapshot), .refreshing(let snapshot), .stale(let snapshot, _):
            if let displayed = displayedQuota(in: snapshot) {
                let reset = displayed.quota.resetsAt.map(Self.longDateFormatter.string) ?? "未知时间"
                description = "\(displaySourceTitle) \(displayed.title)额度剩余 \(displayed.quota.remainingPercent)%，\(reset) 重置"
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
