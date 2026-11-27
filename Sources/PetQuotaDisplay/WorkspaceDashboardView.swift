import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceDashboardView: View {
    @ObservedObject var model: WorkspaceDashboardModel

    private enum Section: String, CaseIterable {
        case accounts, instances, gateway

        var title: String {
            switch self {
            case .accounts: return "账号与额度"
            case .instances: return "客户端实例"
            case .gateway: return "API 网关"
            }
        }

        var symbol: String {
            switch self {
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

    @State private var section = Section.accounts
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
            case .member: WorkspaceGatewayMemberEditor(model: model)
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
                    .foregroundStyle(.teal)
                Text("PetQuota").font(.system(size: 20, weight: .semibold))
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
                            .background(section == item ? Color.teal.opacity(0.16) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                }
            }
            Spacer()
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 24)
        .frame(width: 180)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(section.title).font(.system(size: 26, weight: .semibold))
            Spacer()
            switch section {
            case .accounts:
                Button { model.refreshSelected() } label: { Label("刷新所选账号", systemImage: "arrow.clockwise") }
                Menu {
                    Button("登录新的 Codex 账号…") { model.startCodexLogin?(nil) }
                    Divider()
                    ForEach(WorkspacePlatform.allCases) { platform in
                        Button("添加 \(platform.title) 账号…") { editor = .account(platform) }
                    }
                } label: { Label("添加账号", systemImage: "plus") }
                .fixedSize()
            case .instances:
                Button { editor = .instance(nil) } label: { Label("新建实例", systemImage: "plus") }
            case .gateway:
                Button { editor = .member } label: { Label("添加成员", systemImage: "plus") }
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 19)
    }

    private var accounts: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                ForEach(WorkspacePlatform.allCases) { platform in
                    let entries = model.accounts.filter { $0.platform == platform }
                    VStack(alignment: .leading, spacing: 11) {
                        Text(platform.title).font(.headline)
                        if entries.isEmpty {
                            Text("尚无账号").font(.callout).foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 12)], spacing: 12) {
                                ForEach(entries) { account in accountCard(account) }
                            }
                        }
                    }
                }
            }
            .padding(26)
        }
    }

    private func accountCard(_ account: WorkspaceAccount) -> some View {
        let selected = model.selectedAccount(for: account.platform) == account.id
        let quota = model.quotas[account.id]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(account.name).font(.headline).lineLimit(2)
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
            if selected {
                Label("当前选择", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.teal)
            } else {
                Button("选择此账号") { model.select(account) }.buttonStyle(.link)
            }
            Divider()
            if quota?.isRefreshing == true {
                ProgressView("正在读取额度").controlSize(.small)
            }
            if let quota, !quota.values.isEmpty {
                ForEach(quota.values.prefix(3)) { value in quotaRow(value) }
                if quota.values.count > 3 {
                    DisclosureGroup("其他额度") {
                        ForEach(quota.values.dropFirst(3)) { value in quotaRow(value) }
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
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.teal.opacity(0.48) : Color.primary.opacity(0.10)))
    }

    private func quotaRow(_ quota: WorkspaceQuota) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(quota.title).lineLimit(2)
                Spacer()
                if let percent = quota.percent { Text("\(percent)%").monospacedDigit() }
            }
            if let percent = quota.percent {
                ProgressView(value: Double(percent), total: 100).tint(percent <= 20 ? .orange : .teal)
                    .accessibilityLabel("\(quota.title)剩余")
            }
            let reset = quota.resetsAt.map { "重置 \($0.formatted(date: .abbreviated, time: .shortened))" }
            let detail = [quota.detail, reset].compactMap { $0 }.joined(separator: " · ")
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .font(.callout)
    }

    private var instances: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.settings.instances.isEmpty {
                    Text("新建实例时选择账号和项目目录。").foregroundStyle(.secondary)
                }
                ForEach(model.settings.instances) { instance in
                    let account = model.accounts.first { $0.id == instance.accountID }
                    HStack(spacing: 12) {
                        Image(systemName: "terminal").foregroundStyle(.teal).font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(instance.name).font(.headline)
                            Text([account?.platform.title, account?.name ?? "账号已移除", instance.gatewayMemberID == nil ? nil : "本机 API 网关"]
                                .compactMap { $0 }.joined(separator: " · "))
                                .foregroundStyle(.secondary)
                            Text(instance.projectPath).font(.caption.monospaced()).textSelection(.enabled)
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
                    .padding(13)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var gateway: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Circle().fill(gatewayReady ? Color.green : Color.secondary).frame(width: 8, height: 8)
                Text(gatewayLabel).font(.callout.weight(.medium))
                Spacer()
                TextField("端口", text: $port).frame(width: 78).disabled(gatewayActive)
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
            Divider()
            Text("网关成员").font(.headline)
            if model.settings.gatewayMembers.isEmpty { Text("添加一个 OpenAI API Key 以启动网关。").foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(model.settings.gatewayMembers) { member in
                        HStack {
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
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(maxHeight: model.settings.gatewayMembers.isEmpty ? 0 : 112)
            Divider()
            requestHistory
        }
        .padding(26)
    }

    private var requestHistory: some View {
        let records = requestFilter.apply(to: model.requests)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("请求记录").font(.headline)
                Spacer()
                if !model.requests.isEmpty {
                    TextField("成员、模型、路径或状态码", text: $requestFilter.query)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 230)
                        .accessibilityLabel("搜索请求记录")
                    Toggle("只看异常", isOn: $requestFilter.failuresOnly)
                        .toggleStyle(.checkbox)
                        .help("显示 HTTP 错误和传输中断的请求")
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
