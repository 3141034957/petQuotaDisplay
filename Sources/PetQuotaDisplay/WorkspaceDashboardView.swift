import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceDashboardView: View {
    @ObservedObject var model: WorkspaceDashboardModel

    private enum Section: String, CaseIterable {
        case overview, accounts, instances, gateway

        var title: String {
            switch self {
            case .overview: return "工作台总览"
            case .accounts: return "账号与额度"
            case .instances: return "客户端实例"
            case .gateway: return "API 网关"
            }
        }

        var symbol: String {
            switch self {
            case .overview: return "rectangle.grid.2x2"
            case .accounts: return "person.crop.rectangle.stack"
            case .instances: return "rectangle.on.rectangle"
            case .gateway: return "point.3.connected.trianglepath.dotted"
            }
        }
    }

    private enum Editor: Identifiable {
        case account(WorkspacePlatform), instance(WorkspaceInstance?, accountID: String? = nil), member

        var id: String {
            switch self {
            case .account(let platform): return "account-\(platform.rawValue)"
            case .instance(let instance, _): return instance?.id.uuidString ?? "instance-new"
            case .member: return "gateway-member"
            }
        }
    }

    @State private var section = Section.overview
    @State private var platformFilter: WorkspacePlatform?
    @State private var accountSearch = ""
    @State private var instanceSearch = ""
    @State private var showMembers = false
    @State private var editor: Editor?
    @State private var deletion: (title: String, action: () -> Void)?
    @State private var port = ""
    @State private var requestFilter = GatewayRequestFilter()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                switch section {
                case .overview:
                    WorkspaceOverview(model: model) { platform in
                        accountSearch = ""
                        platformFilter = platform
                        section = .accounts
                        if !model.accounts.contains(where: { $0.platform == platform }) {
                            editor = .account(platform)
                        }
                    } showInstances: {
                        instanceSearch = ""
                        section = .instances
                    } showRequests: {
                        requestFilter = GatewayRequestFilter()
                        showMembers = false
                        section = .gateway
                    } newInstance: {
                        editor = .instance(nil)
                    }
                case .accounts: accounts
                case .instances: instances
                case .gateway: gateway
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 840, minHeight: 540)
        .onAppear { port = String(model.settings.gatewayPort) }
        .sheet(item: $editor, onDismiss: { model.error = nil }) { editor in
            switch editor {
            case .account(let platform): WorkspaceAccountEditor(model: model, platform: platform)
            case .instance(let instance, let accountID): WorkspaceInstanceEditor(model: model, instance: instance, accountID: accountID)
            case .member: WorkspaceGatewayMemberEditor(model: model) { showMembers = true }
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { editor == nil && model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("关闭", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog(deletion?.title ?? "移除", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
            Button("移除", role: .destructive) {
                deletion?.action()
                deletion = nil
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.mint)
                    .frame(width: 33, height: 33)
                    .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                Text("PetQuota").font(.system(size: 20, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 9)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Section.allCases, id: \.self) { item in
                    Button {
                        section = item
                        model.notice = nil
                    } label: {
                        Label(item.title, systemImage: item.symbol)
                            .font(.system(size: 13, weight: section == item ? .semibold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(section == item ? Color.white.opacity(0.15) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                }
            }
            Spacer()
            if let notice = model.notice {
                Text(notice).font(.caption).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
            }
            Divider().overlay(.white.opacity(0.20))
            Button {
                section = .gateway
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(gatewayReady ? Color.mint : .white.opacity(0.55)).frame(width: 7, height: 7)
                    Text(gatewayLabel).font(.caption)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2)
                }.padding(.horizontal, 8)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 24)
        .frame(width: 180)
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [Color(red: 0.08, green: 0.19, blue: 0.22),
                                            Color(red: 0.07, green: 0.12, blue: 0.17)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(section.title).font(.system(size: 26, weight: .semibold, design: .rounded))
            Spacer()
            switch section {
            case .accounts, .overview:
                Button { model.refreshSelected() } label: { Label("刷新所选账号", systemImage: "arrow.clockwise") }
                Menu {
                    Button("登录新的 Codex 账号…") { model.startCodexLogin?(nil) }
                    Divider()
                    ForEach(WorkspacePlatform.allCases) { platform in
                        Button("添加 \(platform.title) 账号…") { editor = .account(platform) }
                    }
                } label: { Label("添加账号", systemImage: "plus") }
                .fixedSize().menuStyle(.button).buttonStyle(.borderedProminent)
            case .instances:
                Button { editor = .instance(nil) } label: { Label("新建实例", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            case .gateway:
                Button { editor = .member } label: { Label("添加成员", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 19)
    }

    private var accounts: some View {
        let term = accountSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = model.accounts.filter { account in
            (platformFilter == nil || account.platform == platformFilter)
                && (term.isEmpty || account.name.localizedStandardContains(term) || account.platform.title.localizedStandardContains(term))
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Picker("平台", selection: $platformFilter) {
                    Text("全部").tag(nil as WorkspacePlatform?)
                    ForEach(WorkspacePlatform.allCases) { Text($0.title).tag(Optional($0)) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer(minLength: 0)
                TextField("搜索账号或平台", text: $accountSearch)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 200).accessibilityLabel("搜索账号或平台")
            }.padding(.horizontal, 24).padding(.top, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !term.isEmpty && matches.isEmpty {
                        Text("没有匹配的账号").foregroundStyle(.secondary)
                        Button("清除搜索") { accountSearch = "" }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12, alignment: .top)], spacing: 12) {
                        ForEach(WorkspacePlatform.allCases.filter { platformFilter == nil || platformFilter == $0 }) { platform in
                            let entries = matches.filter { $0.platform == platform }
                            ForEach(entries) { account in accountCard(account) }
                            if term.isEmpty && entries.isEmpty {
                                VStack(alignment: .leading, spacing: 14) {
                                    HStack { platform.mark; Text(platform.title).font(.headline) }
                                    Button("添加 \(platform.title) 账号…") { editor = .account(platform) }.buttonStyle(.link)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(14).workspacePanel()
                            }
                        }
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func accountCard(_ account: WorkspaceAccount) -> some View {
        let selected = model.selectedAccount(for: account.platform) == account.id
        let quota = model.quotas[account.id]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                account.platform.mark
                Text(account.platform.title).font(.subheadline.weight(.medium))
                Spacer(minLength: 4)
                if account.credential.reportsQuota {
                    Button { model.refresh(account) } label: { Image(systemName: "arrow.clockwise") }
                        .help("刷新额度")
                        .accessibilityLabel("刷新 \(account.name) 的额度")
                        .disabled(quota?.isRefreshing == true)
                }
                Menu {
                    Button("选择此账号") { model.select(account) }.disabled(selected)
                    Button("为此账号新建实例…") { editor = .instance(nil, accountID: account.id) }
                    if account.credential == .codexLogin, let slot = CodexAccountSlot(rawValue: account.id) {
                        Button("重新登录 Codex…") { model.startCodexLogin?(slot) }
                    }
                    if account.credential != .antigravity {
                        Button("移除账号", role: .destructive) {
                            if account.credential == .codexLogin { model.deleteAccount(account) }
                            else { deletion = ("移除 \(account.name)？", { model.deleteAccount(account) }) }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("\(account.name) 的操作")
            }
            Text(account.name).font(.system(size: 17, weight: .semibold)).lineLimit(2)
            if selected {
                Label("当前选择", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(account.platform.tint)
            } else {
                Button("选择此账号") { model.select(account) }.buttonStyle(.link)
            }
            Divider()
            if quota?.isRefreshing == true {
                ProgressView("正在读取额度").controlSize(.small)
            }
            if let quota, !quota.values.isEmpty {
                ForEach(quota.values.prefix(3)) { value in quotaRow(value, tint: account.platform.tint) }
                if quota.values.count > 3 {
                    DisclosureGroup("其他额度") {
                        ForEach(quota.values.dropFirst(3)) { value in quotaRow(value, tint: account.platform.tint) }
                    }
                }
                if let time = quota.updatedAt {
                    let label = quota.error == nil ? "采集于" : "上次成功采集于"
                    Text("\(label) \(time.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if quota?.isRefreshing != true, quota?.error == nil {
                Text(account.credential.reportsQuota ? "点击刷新读取平台额度" : "API Key 账号由平台控制台提供用量")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = quota?.error {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspacePanel(tint: selected ? account.platform.tint : .secondary)
    }

    private func quotaRow(_ quota: WorkspaceQuota, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(quota.title).lineLimit(2)
                Spacer()
                if let percent = quota.percent {
                    Text("\(percent)%").monospacedDigit().accessibilityLabel("剩余 \(percent)%")
                }
            }
            if let percent = quota.percent {
                WorkspaceQuotaMeter(percent: percent, tint: tint)
            }
            let reset = quota.resetsAt.map { "重置 \($0.formatted(date: .abbreviated, time: .shortened))" }
            let detail = [quota.detail, reset].compactMap { $0 }.joined(separator: " · ")
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .font(.callout)
    }

    private var instances: some View {
        let term = instanceSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = model.settings.instances.filter { instance in
            let account = model.accounts.first { $0.id == instance.accountID }
            return term.isEmpty || [instance.name, instance.projectPath, account?.name ?? "", account?.platform.title ?? ""]
                .contains { $0.localizedStandardContains(term) }
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.settings.instances.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 30)).foregroundStyle(.teal)
                        Text("还没有客户端实例").font(.headline)
                        Text("新建实例时选择账号和项目目录。").foregroundStyle(.secondary)
                    }.padding(32).frame(maxWidth: .infinity).workspacePanel()
                } else {
                    HStack {
                        Text("项目实例 · \(visible.count)").font(.headline)
                        Spacer()
                        TextField("搜索项目、目录或账号", text: $instanceSearch)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    }
                    if visible.isEmpty {
                        Button("没有匹配的实例 · 清除搜索") { instanceSearch = "" }.buttonStyle(.link)
                    }
                }
                ForEach(visible) { instance in
                    let account = model.accounts.first { $0.id == instance.accountID }
                    HStack(spacing: 12) {
                        if let account { account.platform.mark }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(instance.name).font(.headline).lineLimit(2)
                            Text([account?.platform.title, account?.name ?? "账号已移除", instance.gatewayMemberID == nil ? nil : "本机 API 网关"]
                                .compactMap { $0 }.joined(separator: " · "))
                                .foregroundStyle(.secondary)
                            Text(instance.projectPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(instance.projectPath).textSelection(.enabled)
                        }
                        Spacer()
                        Button(instance.opensDesktop == true ? "打开桌面端" : "打开终端") { model.launch(instance) }.disabled(account == nil)
                        Button("编辑") { editor = .instance(instance) }
                        Menu {
                            Button("复制为新实例…") { editor = .instance(instance.draftCopy()) }
                            Button("移除实例", role: .destructive) {
                                deletion = ("移除 \(instance.name)？", { model.removeInstance(instance.id) })
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("\(instance.name) 的操作")
                    }
                    .padding(14).workspacePanel()
                }
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var gateway: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Circle().fill(gatewayReady ? Color.green : Color.secondary).frame(width: 8, height: 8)
                    Text(gatewayLabel).font(.callout.weight(.medium))
                    Spacer()
                    Text("端口").font(.caption).foregroundStyle(.secondary)
                    TextField("端口", text: $port).frame(width: 68).disabled(gatewayActive)
                    if gatewayActive {
                        Button("停止") { model.stopGateway() }
                    } else {
                        Button("启动网关") { model.startGateway(port: port) }
                            .disabled(model.settings.gatewayMembers.isEmpty)
                    }
                }
                if case .ready(let bound) = model.gatewayState {
                    let url = "http://127.0.0.1:\(bound)/v1"
                    HStack {
                        Text(url).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Button("复制地址") { QuotaClipboard.copy(url) }.buttonStyle(.link)
                    }
                }
                if case .failed(let message) = model.gatewayState { Text(message).font(.callout).foregroundStyle(.orange) }
                else if model.settings.gatewayMembers.isEmpty {
                    Text("添加一个 OpenAI API Key 以启动网关。").font(.callout).foregroundStyle(.secondary)
                }
            }.padding(16).workspacePanel(tint: gatewayReady ? .teal : .secondary)
            Picker("网关视图", selection: $showMembers) {
                Text("请求记录 · \(model.requests.count)").tag(false)
                Text("网关成员 · \(model.settings.gatewayMembers.count)").tag(true)
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            if showMembers {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.settings.gatewayMembers.isEmpty {
                            Text("还没有网关成员").foregroundStyle(.secondary)
                                .padding(16).frame(maxWidth: .infinity, alignment: .leading).workspacePanel()
                        }
                        ForEach(model.settings.gatewayMembers) { member in
                            HStack {
                                Image(systemName: "key.fill").foregroundStyle(.teal).frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(member.name).fontWeight(.medium)
                                    if let account = model.accounts.first(where: { $0.id == member.codexAccountID }) {
                                        Text(account.name).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button("复制本机 Key") { model.copyGatewayKey(member) }
                                Button("移除") {
                                    deletion = ("移除 \(member.name)？", { model.removeGatewayMember(member) })
                                }
                            }
                            .padding(14).workspacePanel()
                        }
                    }
                }
            } else {
                requestHistory
            }
        }
        .padding(26)
    }

    private var requestHistory: some View {
        let records = requestFilter.apply(to: model.requests)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if !model.requests.isEmpty {
                    TextField("成员、模型、路径或状态码", text: $requestFilter.query)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 230)
                        .accessibilityLabel("搜索请求记录")
                    Toggle("只看异常", isOn: $requestFilter.failuresOnly)
                        .toggleStyle(.checkbox)
                        .help("显示 HTTP 错误和传输中断的请求")
                    Spacer()
                    Text("\(records.count) 条").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Table(records) {
                TableColumn("时间") { row in Text(row.time.formatted(date: .omitted, time: .standard)) }.width(min: 64, ideal: 72)
                TableColumn("路径", value: \.path).width(min: 105, ideal: 135)
                TableColumn("成员", value: \.member).width(min: 65, ideal: 90)
                TableColumn("模型") { row in Text(row.model ?? "—") }.width(min: 60, ideal: 95)
                TableColumn("HTTP") { row in
                    Text(row.interrupted == true ? "\(row.status) 中断" : String(row.status))
                        .foregroundStyle(row.isFailure ? Color.orange : Color.primary)
                }.width(min: 44, ideal: 64)
                TableColumn("耗时") { row in Text(String(format: "%.2f s", row.duration)).monospacedDigit() }
                    .width(min: 48, ideal: 58)
            }
            .overlay {
                if model.requests.isEmpty {
                    Text("网关转发请求后会显示记录").foregroundStyle(.secondary).allowsHitTesting(false)
                } else if records.isEmpty {
                    VStack(spacing: 6) {
                        Text("没有匹配的请求").foregroundStyle(.secondary)
                        Button("清除筛选") { requestFilter = GatewayRequestFilter() }.buttonStyle(.link)
                    }
                }
            }
        }
    }

    private var gatewayActive: Bool {
        switch model.gatewayState {
        case .starting, .ready: return true
        default: return false
        }
    }

    private var gatewayReady: Bool {
        if case .ready = model.gatewayState { return true }
        return false
    }

    private var gatewayLabel: String {
        switch model.gatewayState {
        case .ready: return "本机网关运行中"
        case .starting: return "正在启动"
        case .stopped, .failed: return "网关已停止"
        }
    }
}

private struct WorkspaceAccountEditor: View {
    @ObservedObject var model: WorkspaceDashboardModel
    let platform: WorkspacePlatform
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var region = "global"
    @State private var project = ""
    @State private var key = ""
    @State private var isToken = false
    @State private var file: URL?
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加 \(platform.title) 账号").font(.title2.weight(.semibold))
            TextField("本地账号名称", text: $name)
            if platform == .codeBuddy {
                Picker("账号区域", selection: $region) {
                    Text("国际").tag("global")
                    Text("中国大陆").tag("cn")
                }.pickerStyle(.segmented)
            }
            HStack {
                Button("选择登录 JSON…") { choosing = true }
                Text(file?.lastPathComponent ?? fileHint).font(.caption).foregroundStyle(.secondary)
            }
            if platform == .gemini, file != nil {
                TextField("Google Cloud 项目标识（可选）", text: $project)
            }
            if file == nil {
                if platform == .codeBuddy { Toggle("使用账号访问令牌", isOn: $isToken) }
                SecureField(isToken ? "访问令牌" : "API Key", text: $key)
            }
            WorkspaceEditorError(message: model.error)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button(file == nil ? "添加" : "导入") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (file == nil && key.isEmpty))
            }
        }
        .padding(22)
        .frame(width: 420)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                file = url
                key = ""
            case .failure(let error): model.error = error.localizedDescription
            }
        }
    }

    private var fileHint: String {
        switch platform {
        case .codex: return "Codex auth.json"
        case .codeBuddy: return "包含 access_token 的账号文件"
        case .gemini: return "Gemini CLI oauth_creds.json"
        }
    }

    private func save() {
        let successful: Bool
        if let file {
            let access = file.startAccessingSecurityScopedResource()
            defer { if access { file.stopAccessingSecurityScopedResource() } }
            successful = model.importAccount(platform: platform, name: name, file: file, region: region, project: project)
        } else {
            successful = model.addAccountKey(platform: platform, name: name, value: key, region: region, isToken: isToken)
        }
        if successful {
            key = ""
            dismiss()
        }
    }
}

private struct WorkspaceInstanceEditor: View {
    @ObservedObject var model: WorkspaceDashboardModel
    @Environment(\.dismiss) private var dismiss
    private let id: UUID
    private let editing: Bool
    @State private var name: String
    @State private var accountID: String
    @State private var path: String
    @State private var gatewayMemberID: UUID?
    @State private var opensDesktop: Bool

    init(model: WorkspaceDashboardModel, instance: WorkspaceInstance?, accountID: String?) {
        self.model = model
        id = instance?.id ?? UUID()
        editing = model.settings.instances.contains { $0.id == instance?.id }
        _name = State(initialValue: instance?.name ?? "")
        _accountID = State(initialValue: instance?.accountID ?? accountID ?? model.selectedAccount(for: .codex) ?? model.accounts.first?.id ?? "")
        _path = State(initialValue: instance?.projectPath ?? "")
        _gatewayMemberID = State(initialValue: instance?.gatewayMemberID)
        _opensDesktop = State(initialValue: instance?.opensDesktop == true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing ? "编辑客户端实例" : "新建客户端实例").font(.title2.weight(.semibold))
            TextField("实例名称", text: $name)
            Picker("账号", selection: $accountID) {
                ForEach(model.accounts) { account in
                    Text("\(account.platform.title) · \(account.name)").tag(account.id)
                }
            }
            if model.accounts.first(where: { $0.id == accountID })?.credential == .codexLogin {
                Picker("客户端", selection: $opensDesktop) {
                    Text("命令行").tag(false)
                    Text("Codex 桌面端").tag(true)
                }
            }
            if model.accounts.first(where: { $0.id == accountID })?.platform == .codex, !opensDesktop {
                Picker("API 网关", selection: $gatewayMemberID) {
                    Text("直接连接 Codex").tag(nil as UUID?)
                    ForEach(model.settings.gatewayMembers) { member in Text(member.name).tag(Optional(member.id)) }
                }
            }
            HStack {
                TextField("项目目录，例如 ~/Projects", text: $path)
                    .help("支持绝对路径、~/ 路径和本机 file:// 链接")
                Button("选择目录…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { path = url.path }
                }
            }
            WorkspaceEditorError(message: model.error)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("保存") {
                    if model.saveInstance(id: id, name: name, accountID: accountID, path: path,
                                          gatewayMemberID: opensDesktop ? nil : gatewayMemberID, opensDesktop: opensDesktop) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || accountID.isEmpty || path.isEmpty)
            }
        }
        .padding(22).frame(width: 470)
        .onChange(of: accountID) { _ in
            gatewayMemberID = nil
            opensDesktop = false
        }
    }
}

private struct WorkspaceGatewayMemberEditor: View {
    @ObservedObject var model: WorkspaceDashboardModel
    let didSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var key = ""
    @State private var accountID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加网关成员").font(.title2.weight(.semibold))
            TextField("成员名称", text: $name)
            Picker("关联 Codex 账号", selection: $accountID) {
                Text("独立 API Key").tag(nil as String?)
                ForEach(model.accounts.filter { $0.platform == .codex }) { account in
                    Text(account.credential == .codexKey ? "\(account.name) · 已保存 API Key" : account.name)
                        .tag(Optional(account.id))
                }
            }
            if !usesSavedKey { SecureField("OpenAI API Key", text: $key) }
            Text("客户端使用该成员独立的本机 Key。")
                .font(.caption).foregroundStyle(.secondary)
            WorkspaceEditorError(message: model.error)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("添加") {
                    if model.saveGatewayMember(name: name, key: usesSavedKey ? "" : key, accountID: accountID) {
                        key = ""
                        didSave()
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || (!usesSavedKey && key.isEmpty))
            }
        }
        .padding(22).frame(width: 420)
    }

    private var usesSavedKey: Bool {
        model.accounts.contains { $0.id == accountID && $0.credential == .codexKey }
    }
}

private struct WorkspaceEditorError: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
