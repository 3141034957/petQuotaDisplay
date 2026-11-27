import SwiftUI

extension WorkspacePlatform {
    var tint: Color {
        switch self {
        case .codex: return .teal
        case .codeBuddy: return .indigo
        case .gemini: return .purple
        }
    }

    var symbol: String {
        switch self {
        case .codex: return "terminal.fill"
        case .codeBuddy: return "chevron.left.forwardslash.chevron.right"
        case .gemini: return "sparkles"
        }
    }

    var mark: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
    }
}

extension View {
    func workspacePanel(tint: Color = .secondary) -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.25)))
    }
}

struct WorkspaceQuotaMeter: View {
    let percent: Int
    let tint: Color

    var body: some View {
        GeometryReader { bounds in
            Capsule().fill(Color.secondary.opacity(0.16))
                .overlay(alignment: .leading) {
                    Capsule().fill(percent <= 20 ? Color.orange : tint)
                        .frame(width: bounds.size.width * CGFloat(min(100, max(0, percent))) / 100)
                }
        }.frame(height: 5).accessibilityHidden(true)
    }
}

struct WorkspaceOverview: View {
    @ObservedObject var model: WorkspaceDashboardModel
    let showAccounts: (WorkspacePlatform) -> Void
    let showInstances: () -> Void
    let showRequests: () -> Void
    let newInstance: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("当前账号额度").font(.headline)
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(WorkspacePlatform.allCases) { platform in
                            platformCard(platform)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeading("项目实例", action: showInstances)
                    if model.settings.instances.isEmpty {
                        HStack {
                            Label("还没有项目实例", systemImage: "folder").foregroundStyle(.secondary)
                            Spacer()
                            Button("新建实例…", action: newInstance)
                        }.padding(14).workspacePanel()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(model.settings.instances.prefix(3)) { instance in
                                let account = model.accounts.first { $0.id == instance.accountID }
                                HStack(spacing: 12) {
                                    if let account { account.platform.mark }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(instance.name).fontWeight(.medium).lineLimit(1)
                                        Text(instance.projectPath).font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle).help(instance.projectPath)
                                    }
                                    Spacer()
                                    Text(account?.name ?? "账号已移除").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Button { model.launch(instance) } label: { Label("打开", systemImage: "play.fill") }
                                        .disabled(account == nil)
                                }.padding(.horizontal, 14).padding(.vertical, 10)
                                if instance.id != model.settings.instances.prefix(3).last?.id { Divider() }
                            }
                        }.workspacePanel()
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeading("最近网关请求", action: showRequests)
                    if model.requests.isEmpty {
                        Label("网关转发首个请求后，记录会出现在这里。", systemImage: "arrow.left.arrow.right")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14).workspacePanel()
                    } else {
                        VStack(spacing: 8) {
                            ForEach(model.requests.prefix(3)) { row in
                                HStack(spacing: 12) {
                                    Text(row.interrupted == true ? "\(row.status) 中断" : String(row.status))
                                        .font(.caption.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(row.isFailure ? Color.orange : Color.primary)
                                    Text(row.model ?? row.path).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(row.member).lineLimit(1)
                                    Text(row.time.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                                }.font(.callout)
                            }
                        }.padding(14).workspacePanel()
                    }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionHeading(_ title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Button("查看全部", action: action).buttonStyle(.link).accessibilityLabel("查看全部\(title)")
        }
    }

    private func platformCard(_ platform: WorkspacePlatform) -> some View {
        let selectedID = model.selectedAccount(for: platform)
        let account = model.accounts.first { $0.id == selectedID }
        let state = account.flatMap { model.quotas[$0.id] }
        let value = state?.overviewQuota
        let detail: String
        if state?.isRefreshing == true { detail = "正在刷新…" }
        else if state?.error != nil { detail = value.map { "上次读数 · \($0.title)" } ?? "读取失败" }
        else if let value { detail = value.percent != nil ? "最低余量 · \(value.title)" : value.title }
        else if account == nil { detail = "添加账号…" }
        else if account?.credential.reportsQuota == false { detail = "平台控制台用量" }
        else { detail = "等待读取额度" }

        return Button {
            showAccounts(platform)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    platform.mark
                    Text(platform.title).font(.headline)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                }
                Text(account?.name ?? "尚未配置账号").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(value?.percent.map { "\($0)%" } ?? value?.detail ?? "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.58)
                if let percent = value?.percent {
                    WorkspaceQuotaMeter(percent: percent, tint: platform.tint)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(detail)
            }
            .frame(maxWidth: .infinity, minHeight: 125, alignment: .topLeading)
            .padding(13).workspacePanel(tint: platform.tint)
        }
        .buttonStyle(.plain)
        .help("查看 \(platform.title) 账号。百分比为所选账号各额度周期中的最低余量。")
    }
}
