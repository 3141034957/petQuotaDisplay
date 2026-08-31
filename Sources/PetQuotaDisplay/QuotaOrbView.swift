import AppKit
import QuotaCore

final class QuotaOrbView: NSView {
    private static let designDiameter: CGFloat = 148
    private static let displayedWindowDefaultsKey = "quota.displayedWindow"

    private enum DisplayedWindow: String {
        case fiveHour
        case weekly

        var title: String {
            switch self {
            case .fiveHour: return "5 小时"
            case .weekly: return "本周"
            }
        }
    }

    enum State {
        case loading
        case loaded(QuotaSnapshot)
        case failed(String)
    }

    var state: State = .loading {
        didSet {
            needsDisplay = true
            updateAccessibility()
        }
    }
    var onRefresh: (() -> Void)?
    var onQuit: (() -> Void)?
    var onPositionChanged: (() -> Void)?
    var onSelectAccount: ((CodexAccountSlot) -> Void)?
    var onAddAccount: (() -> Void)?
    var onLoginAccount: ((CodexAccountSlot) -> Void)?
    var onDeleteAccount: ((CodexAccountSlot) -> Void)?
    var accounts: [CodexAccountSlot] = []
    var selectedAccount: CodexAccountSlot?
    var accountStatuses: [CodexAccountSlot: CodexAccountStatus] = [:]
    var quitMenuTitle = "退出额度悬浮球"

    private var mouseDownLocation: NSPoint?
    private var windowOriginAtMouseDown: NSPoint?
    private var dragged = false
    private var displayedWindow: DisplayedWindow = .weekly

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        if let saved = UserDefaults.standard.string(forKey: Self.displayedWindowDefaultsKey),
           let displayedWindow = DisplayedWindow(rawValue: saved) {
            self.displayedWindow = displayedWindow
        }
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
        guard case .loaded(let snapshot) = state else {
            if case .failed = state {
                return NSColor(calibratedRed: 0.36, green: 0.39, blue: 0.45, alpha: 1)
            }
            return NSColor(calibratedRed: 0.32, green: 0.37, blue: 0.48, alpha: 1)
        }
        let remaining = displayedQuota(in: snapshot).remainingPercent
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

        guard case .loaded(let snapshot) = state else { return }
        let center = NSPoint(x: ringRect.midX, y: ringRect.midY)
        let quota = displayedQuota(in: snapshot)
        let progress = NSBezierPath()
        progress.appendArc(
            withCenter: center,
            radius: ringRect.width / 2,
            startAngle: 90,
            endAngle: 90 - CGFloat(quota.remainingPercent) * 3.6,
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
            drawCentered("连接 Codex", y: 99, font: .systemFont(ofSize: 11, weight: .medium), alpha: 0.78)
        case .failed:
            drawCentered("额度暂不可用", y: 34, font: .systemFont(ofSize: 12, weight: .medium), alpha: 0.82)
            drawCentered("—", y: 51, font: .systemFont(ofSize: 35, weight: .bold), alpha: 1)
            drawCentered("单击重试", y: 100, font: .systemFont(ofSize: 11, weight: .medium), alpha: 0.78)
        case .loaded(let snapshot):
            let quota = displayedQuota(in: snapshot)
            drawCentered(
                "\(displayedWindow.title)额度",
                y: 28,
                font: .systemFont(ofSize: 11, weight: .medium),
                alpha: 0.82
            )
            drawCentered(
                "\(quota.remainingPercent)%",
                y: 43,
                font: .monospacedDigitSystemFont(ofSize: 38, weight: .bold),
                alpha: 1
            )
            let reset = quota.resetsAt.map(Self.shortDateFormatter.string) ?? "时间未知"
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
        dragged = dragged || hypot(dx, dy) > 3
        window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if dragged {
            onPositionChanged?()
        } else {
            onRefresh?()
        }
        mouseDownLocation = nil
        windowOriginAtMouseDown = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Codex Token 额度")
        let refresh = NSMenuItem(title: "立即刷新", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

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
        menu.addItem(accountItem)
        menu.addItem(.separator())

        let fiveHour = NSMenuItem(title: "展示 5 小时额度", action: #selector(selectDisplayedWindow(_:)), keyEquivalent: "")
        fiveHour.target = self
        fiveHour.representedObject = DisplayedWindow.fiveHour.rawValue
        fiveHour.state = displayedWindow == .fiveHour ? .on : .off
        menu.addItem(fiveHour)

        let weekly = NSMenuItem(title: "展示本周额度", action: #selector(selectDisplayedWindow(_:)), keyEquivalent: "")
        weekly.target = self
        weekly.representedObject = DisplayedWindow.weekly.rawValue
        weekly.state = displayedWindow == .weekly ? .on : .off
        menu.addItem(weekly)
        menu.addItem(.separator())

        if case .loaded(let snapshot) = state {
            let quota = displayedQuota(in: snapshot)
            let reset = quota.resetsAt.map(Self.longDateFormatter.string) ?? "未知"
            let detail = NSMenuItem(
                title: "\(displayedWindow.title)额度：剩余 \(quota.remainingPercent)% · \(reset) 重置",
                action: nil,
                keyEquivalent: ""
            )
            detail.isEnabled = false
            menu.addItem(detail)
            menu.addItem(.separator())
        } else if case .failed(let message) = state {
            let detail = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)
            menu.addItem(.separator())
        }

        let quit = NSMenuItem(title: quitMenuTitle, action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func refreshFromMenu() { onRefresh?() }
    @objc private func quitFromMenu() { onQuit?() }

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

    @objc private func deleteAccountFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let account = CodexAccountSlot(rawValue: rawValue) else { return }
        onDeleteAccount?(account)
    }

    @objc private func selectDisplayedWindow(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let selected = DisplayedWindow(rawValue: rawValue) else { return }
        displayedWindow = selected
        UserDefaults.standard.set(selected.rawValue, forKey: Self.displayedWindowDefaultsKey)
        needsDisplay = true
        updateAccessibility()
    }

    private func displayedQuota(in snapshot: QuotaSnapshot) -> QuotaWindow {
        switch displayedWindow {
        case .fiveHour: return snapshot.fiveHour
        case .weekly: return snapshot.weekly
        }
    }

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
        let index = accounts.firstIndex(of: slot).map { $0 + 1 } ?? 1
        return "额度账号 \(index)"
    }

    private func updateAccessibility() {
        let description: String
        switch state {
        case .loading:
            description = "Codex Token 额度正在同步"
        case .failed(let message):
            description = "Codex Token 额度不可用，\(message)"
        case .loaded(let snapshot):
            let quota = displayedQuota(in: snapshot)
            let reset = quota.resetsAt.map(Self.longDateFormatter.string) ?? "未知时间"
            description = "Codex \(displayedWindow.title)额度剩余 \(quota.remainingPercent)%，\(reset) 重置"
        }
        setAccessibilityLabel(description)
        setAccessibilityHelp("可拖动悬浮球；单击刷新；右键切换账号、5 小时或本周额度")
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
