import AppKit
import Foundation
import QuotaCore
import SwiftUI

final class WorkspaceDashboardModel: ObservableObject {
    struct QuotaState {
        var values: [WorkspaceQuota] = []
        var updatedAt: Date?
        var error: String?
        var isRefreshing = false
    }

    @Published private(set) var settings = WorkspaceSettings()
    @Published private(set) var accounts: [WorkspaceAccount] = []
    @Published private(set) var quotas: [String: QuotaState] = [:]
    @Published private(set) var gatewayState: WorkspaceGateway.State = .stopped
    @Published private(set) var requests: [GatewayRequestRecord] = []
    @Published var notice: String?
    @Published var error: String?

    var selectCodex: ((CodexAccountSlot) -> Void)?
    var startCodexLogin: ((CodexAccountSlot?) -> Void)?
    var refreshActiveCodex: ((CodexAccountSlot) -> Bool)?
    var removeCodex: ((CodexAccountSlot) -> Void)?
    var getSelectedCodex: (() -> CodexAccountSlot?)?

    private struct Refresh {
        let id: UUID
        let deadline: DispatchWorkItem
        let cancel: () -> Void
    }

    private let store: WorkspaceStore
    private let accountService: WorkspaceAccountService
    private let gateway: WorkspaceGateway
    private var running: [String: Refresh] = [:]

    init(store: WorkspaceStore = .local) {
        self.store = store
        accountService = WorkspaceAccountService(store: store)
        gateway = WorkspaceGateway(logFile: store.gatewayLog)
        requests = WorkspaceGateway.readRecords(from: store.gatewayLog)
        gateway.onState = { [weak self] in self?.gatewayState = $0 }
        gateway.onRecords = { [weak self] in self?.requests = $0 }
        reload()
    }

    func reload() {
        attempt {
            settings = try store.load()
            accounts = accountService.accounts(in: settings)
        }
    }

    func selectedAccount(for platform: WorkspacePlatform) -> String? {
        let available = accounts.filter { $0.platform == platform }
        let saved = available.first { $0.id == settings.selectedAccounts[platform.rawValue] }
        if platform == .codex, saved?.credential != .codexKey, let active = getSelectedCodex?() { return active.rawValue }
        return saved?.id ?? available.first?.id
    }

    func select(_ account: WorkspaceAccount) {
        attempt {
            settings = try store.update { $0.selectedAccounts[account.platform.rawValue] = account.id }
            if account.credential == .codexLogin, let slot = CodexAccountSlot(rawValue: account.id) { selectCodex?(slot) }
            notice = "已选择 \(account.name)"
        }
    }

    func importAccount(platform: WorkspacePlatform, name: String, file: URL, region: String, project: String) -> Bool {
        attempt {
            let label = try validName(name)
            let data = try WorkspaceStore.readImport(file)
            let id = try accountService.importJSON(data, platform: platform, name: label, region: region, project: project)
            reload()
            if let account = accounts.first(where: { $0.id == id }) { select(account) }
            notice = "已导入 \(label)"
        }
    }

    func addAccountKey(platform: WorkspacePlatform, name: String, value: String, region: String, isToken: Bool) -> Bool {
        attempt {
            let label = try validName(name)
            let id = try accountService.addSecret(platform: platform, name: label, value: value, region: region, isToken: isToken)
            reload()
            if let account = accounts.first(where: { $0.id == id }) { select(account) }
            notice = "已添加 \(label)"
        }
    }

    func deleteAccount(_ account: WorkspaceAccount) {
        attempt {
            if account.credential == .codexLogin, let slot = CodexAccountSlot(rawValue: account.id) {
                removeCodex?(slot)
            } else if account.credential != .antigravity {
                settings = try store.update { state in
                    guard !state.referencesAccount(account.id) else { throw WorkspaceError.accountInUse }
                    state.accounts.removeAll { $0.id == account.id }
                    if state.selectedAccounts[account.platform.rawValue] == account.id {
                        state.selectedAccounts.removeValue(forKey: account.platform.rawValue)
                    }
                }
                if account.credential == .geminiLogin {
                    let home = try store.accountHome(account.id)
                    if FileManager.default.fileExists(atPath: home.path) { try FileManager.default.removeItem(at: home) }
                } else {
                    try WorkspaceKeychain.remove(account.id)
                }
            }
            takeRefresh(account.id)?.cancel()
            quotas.removeValue(forKey: account.id)
            reload()
        }
    }

    func refreshSelected() {
        for platform in WorkspacePlatform.allCases {
            if let account = accounts.first(where: { $0.id == selectedAccount(for: platform) }) { refresh(account) }
        }
    }

    func refresh(_ account: WorkspaceAccount) {
        guard account.credential.reportsQuota, running[account.id] == nil else { return }
        let id = UUID()
        let deadline = DispatchWorkItem { [weak self] in
            self?.finish(account.id, request: id, result: .failure(WorkspaceError.quotaRequest(408)))
        }
        quotas[account.id, default: QuotaState()].isRefreshing = true
        quotas[account.id]?.error = nil
        running[account.id] = Refresh(id: id, deadline: deadline, cancel: {})
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: deadline)
        let cancel: () -> Void
        switch account.credential {
        case .codexLogin:
            guard let slot = CodexAccountSlot(rawValue: account.id),
                  CodexAccountProfile.hasStoredCredentials(for: slot) else {
                finish(account.id, request: id, result: .failure(WorkspaceError.missingCredential))
                return
            }
            if refreshActiveCodex?(slot) == true { return }
            do {
                let client = CodexQuotaClient(codexHome: try CodexAccountProfile.homeURL(for: slot, create: false))
                client.onReport = { [weak self] report in
                    self?.finish(account.id, request: id, result: .success(Self.codexQuotas(report)))
                }
                client.onError = { [weak self] error in self?.finish(account.id, request: id, result: .failure(error)) }
                client.onAccount = { [weak self] summary in
                    if summary == nil {
                        self?.finish(account.id, request: id, result: .failure(WorkspaceError.unauthorized))
                    }
                }
                client.start()
                cancel = { client.stop() }
            } catch {
                finish(account.id, request: id, result: .failure(error))
                return
            }
        case .antigravity:
            let client = GeminiQuotaClient()
            client.onResult = { [weak self] response in
                self?.finish(account.id, request: id, result: response.map { WorkspaceQuota.periods($0) })
            }
            client.refresh()
            cancel = { client.stop() }
        default:
            let service = accountService
            let task = Task { @MainActor [weak self] in
                let result: Result<[WorkspaceQuota], Error>
                do { result = .success(try await service.quota(for: account)) }
                catch { result = .failure(error) }
                self?.finish(account.id, request: id, result: result)
            }
            cancel = { task.cancel() }
        }
        if running[account.id]?.id == id {
            running[account.id] = Refresh(id: id, deadline: deadline, cancel: cancel)
        } else {
            cancel()
        }
    }

    func noteCodex(_ slot: CodexAccountSlot, report: CodexQuotaReport) {
        if let request = running[slot.rawValue]?.id {
            finish(slot.rawValue, request: request, result: .success(Self.codexQuotas(report)))
        } else {
            quotas[slot.rawValue] = QuotaState(values: Self.codexQuotas(report), updatedAt: report.primary.fetchedAt)
        }
    }

    func noteCodexFailure(_ slot: CodexAccountSlot, error: Error) {
        if let request = running[slot.rawValue]?.id { finish(slot.rawValue, request: request, result: .failure(error)) }
    }

    private static func codexQuotas(_ report: CodexQuotaReport) -> [WorkspaceQuota] {
        WorkspaceQuota.periods(report.primary) + report.additional.flatMap {
            WorkspaceQuota.periods($0.snapshot, prefix: $0.id + ":", title: $0.name)
        }
    }

    private func takeRefresh(_ account: String) -> Refresh? {
        let refresh = running.removeValue(forKey: account)
        refresh?.deadline.cancel()
        return refresh
    }

    private func finish(_ account: String, request: UUID, result: Result<[WorkspaceQuota], Error>) {
        guard running[account]?.id == request else { return }
        takeRefresh(account)?.cancel()
        var state = quotas[account, default: QuotaState()]
        state.isRefreshing = false
        switch result {
        case .success(let values):
            state.values = values
            state.updatedAt = Date()
            state.error = nil
        case .failure(let error):
            state.error = QuotaQuery.publicErrorDescription(error)
        }
        quotas[account] = state
    }

    func saveInstance(id: UUID, name: String, accountID: String, path: String,
                      gatewayMemberID: UUID?, opensDesktop: Bool) -> Bool {
        attempt {
            let name = try validName(name)
            var isDirectory: ObjCBool = false
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { throw WorkspaceError.invalidProject }
            guard let account = accounts.first(where: { $0.id == accountID }) else { throw WorkspaceError.invalidAccount }
            settings = try store.update { state in
                if account.credential != .codexLogin && account.credential != .antigravity
                    && !state.accounts.contains(where: { $0.id == accountID }) { throw WorkspaceError.invalidAccount }
                if let gatewayMemberID, account.platform != .codex
                    || !state.gatewayMembers.contains(where: { $0.id == gatewayMemberID }) { throw WorkspaceError.invalidAccount }
                if opensDesktop && (account.credential != .codexLogin || gatewayMemberID != nil) {
                    throw WorkspaceError.invalidAccount
                }
                let instance = WorkspaceInstance(id: id, name: name, accountID: accountID,
                                                  projectPath: path, gatewayMemberID: gatewayMemberID, opensDesktop: opensDesktop)
                if let existing = state.instances.firstIndex(where: { $0.id == id }) {
                    state.instances[existing] = instance
                } else {
                    state.instances.append(instance)
                }
            }
        }
    }

    func removeInstance(_ id: UUID) {
        attempt { settings = try store.update { $0.instances.removeAll { $0.id == id } } }
    }

    func launch(_ instance: WorkspaceInstance) {
        attempt {
            if instance.gatewayMemberID != nil {
                guard case .ready = gatewayState else { throw WorkspaceError.gatewayNotRunning }
            }
            guard let launcher = Bundle.main.executableURL, let account = accounts.first(where: { $0.id == instance.accountID }) else {
                throw WorkspaceError.invalidAccount
            }
            let runner = WorkspaceLauncher(store: store)
            if instance.opensDesktop == true {
                try runner.openCodexDesktop(instance, account: account) { [weak self] error in
                    if let error { self?.error = error.localizedDescription }
                    else { self?.notice = "已打开 Codex 桌面实例 \(instance.name)" }
                }
                return
            }
            _ = try runner.plan(for: instance, account: account, settings: settings)
            try runner.open(instance, openingWith: launcher) { [weak self] error in
                if let error { self?.error = error.localizedDescription }
                else { self?.notice = "已在终端打开 \(instance.name)" }
            }
        }
    }

    func saveGatewayMember(name: String, key: String, accountID: String?) -> Bool {
        attempt {
            let name = try validName(name)
            let usesAccountKey = key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if let accountID, !accounts.contains(where: { $0.id == accountID && $0.platform == .codex }) {
                throw WorkspaceError.invalidAccount
            }
            let member = WorkspaceGatewayMember(id: UUID(), name: name, codexAccountID: accountID, usesAccountKey: usesAccountKey)
            let localID = GatewayKeys.local(member.id)
            let upstreamID = GatewayKeys.upstream(member.id)
            do {
                if !usesAccountKey { try WorkspaceKeychain.save(WorkspaceKeychain.normalizedSecret(key), as: upstreamID) }
                try WorkspaceKeychain.save(GatewayKeys.generate(), as: localID)
                settings = try store.update { state in
                    if usesAccountKey, !state.accounts.contains(where: { $0.id == accountID && $0.credential == .codexKey }) {
                        throw WorkspaceError.missingCredential
                    }
                    state.gatewayMembers.append(member)
                }
            } catch {
                try? WorkspaceKeychain.remove(upstreamID)
                try? WorkspaceKeychain.remove(localID)
                throw error
            }
            try refreshGatewayRoutes()
        }
    }

    func removeGatewayMember(_ member: WorkspaceGatewayMember) {
        attempt {
            settings = try store.update { state in
                guard !state.instances.contains(where: { $0.gatewayMemberID == member.id }) else { throw WorkspaceError.accountInUse }
                state.gatewayMembers.removeAll { $0.id == member.id }
            }
            gateway.removeRoute(for: member.id)
            try WorkspaceKeychain.remove(GatewayKeys.local(member.id))
            try WorkspaceKeychain.remove(GatewayKeys.upstream(member.id))
        }
    }

    func copyGatewayKey(_ member: WorkspaceGatewayMember) {
        attempt {
            QuotaClipboard.copy(try WorkspaceKeychain.read(GatewayKeys.local(member.id)))
            notice = "已复制 \(member.name) 的本机 Key"
        }
    }

    func startGateway(port: String) {
        attempt {
            if case .ready = gatewayState { return }
            guard gatewayState != .starting else { return }
            guard let port = UInt16(port.trimmingCharacters(in: .whitespaces)), port >= 1024 else {
                throw WorkspaceError.invalidPort
            }
            settings = try store.update { $0.gatewayPort = port }
            let routes = try GatewayKeys.routes(settings.gatewayMembers)
            gatewayState = .starting
            gateway.start(port: port, routes: routes)
        }
    }

    private func refreshGatewayRoutes() throws {
        switch gatewayState {
        case .starting, .ready:
            gateway.updateRoutes(try GatewayKeys.routes(settings.gatewayMembers))
        case .stopped, .failed:
            break
        }
    }

    func stopGateway() { gateway.stop() }

    func shutdown() {
        for key in Array(running.keys) { takeRefresh(key)?.cancel() }
        gateway.stop()
    }

    @discardableResult
    private func attempt(_ work: () throws -> Void) -> Bool {
        do {
            try work()
            return true
        } catch let failure {
            error = failure.localizedDescription
            return false
        }
    }

    private func validName(_ raw: String) throws -> String {
        let name = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty else { throw WorkspaceError.invalidAccount }
        return String(name.prefix(60))
    }
}
