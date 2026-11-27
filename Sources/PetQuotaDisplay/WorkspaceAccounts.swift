import CoreFoundation
import Foundation
import QuotaCore

struct WorkspaceQuota: Equatable, Identifiable {
    let id: String
    let title: String
    let percent: Int?
    let detail: String?
    let resetsAt: Date?

    static func periods(_ snapshot: QuotaSnapshot, prefix: String = "", title: String? = nil) -> [Self] {
        QuotaPeriod.allCases.compactMap { period in
            guard let window = snapshot[period] else { return nil }
            let name = title.map { "\($0) · \(period.title)" } ?? period.title
            return Self(id: prefix + period.rawValue, title: name,
                        percent: window.remainingPercent, detail: nil, resetsAt: window.resetsAt)
        }
    }
}

struct WorkspaceAccountService {
    static let codeAssist = URL(string: "https://cloudcode-pa.googleapis.com/")!
    static let session = QuotaHTTP.makeSession()
    let store: WorkspaceStore

    func accounts(in settings: WorkspaceSettings) -> [WorkspaceAccount] {
        let codex = CodexAccountProfile.loadAccounts(persistNormalization: false).enumerated().map { index, slot in
            WorkspaceAccount(id: slot.rawValue, platform: .codex,
                             name: CodexAccountProfile.name(for: slot) ?? "Codex 账号 \(index + 1)", credential: .codexLogin)
        }
        return codex + settings.accounts + [.antigravity]
    }

    @discardableResult
    func importJSON(_ data: Data, platform: WorkspacePlatform, name: String,
                    region: String, project: String) throws -> String {
        switch platform {
        case .codex:
            return try CodexAccountProfile.importLogin(data, name: name).rawValue
        case .codeBuddy:
            let document = try Self.object(data)
            let fields = document["data"] as? [String: Any] ?? document
            guard let token = (fields["access_token"] ?? fields["accessToken"]) as? String else {
                throw WorkspaceError.invalidAccountFile
            }
            var account = WorkspaceAccount(id: UUID().uuidString, platform: .codeBuddy,
                                           name: name, credential: .codeBuddyToken)
            account.region = region == "cn" ? "cn" : "global"
            account.userID = Self.identifier(fields["uid"] ?? fields["userId"])
            account.enterpriseID = Self.identifier(fields["enterprise_id"] ?? fields["enterpriseId"])
            account.domain = Self.identifier(fields["domain"])
            try saveSecretAccount(account, value: token)
            return account.id
        case .gemini:
            let document = try Self.object(data)
            guard let access = document["access_token"] as? String,
                  (try? WorkspaceKeychain.normalizedSecret(access)) != nil else {
                throw WorkspaceError.invalidAccountFile
            }
            var account = WorkspaceAccount(id: UUID().uuidString, platform: .gemini, name: name, credential: .geminiLogin)
            account.projectID = Self.identifier(project) ?? Self.identifier(document["project_id"])
            let home = try store.accountHome(account.id)
            let profile = home.appendingPathComponent(".gemini", isDirectory: true)
            do {
                try WorkspaceStore.write(data, to: profile.appendingPathComponent("oauth_creds.json"))
                let loginSettings = ["security": ["auth": ["selectedType": "oauth-personal"]]]
                try WorkspaceStore.write(JSONEncoder().encode(loginSettings), to: profile.appendingPathComponent("settings.json"))
                try store.update { $0.accounts.append(account) }
            } catch {
                try? FileManager.default.removeItem(at: home)
                throw error
            }
            return account.id
        }
    }

    @discardableResult
    func addSecret(platform: WorkspacePlatform, name: String, value: String, region: String, isToken: Bool) throws -> String {
        let credential: WorkspaceCredential
        switch platform {
        case .codex: credential = .codexKey
        case .codeBuddy: credential = isToken ? .codeBuddyToken : .codeBuddyKey
        case .gemini: credential = .geminiKey
        }
        var account = WorkspaceAccount(id: UUID().uuidString, platform: platform, name: name, credential: credential)
        if platform == .codeBuddy { account.region = region == "cn" ? "cn" : "global" }
        try saveSecretAccount(account, value: value)
        return account.id
    }

    private func saveSecretAccount(_ account: WorkspaceAccount, value: String) throws {
        try WorkspaceKeychain.save(try WorkspaceKeychain.normalizedSecret(value), as: account.id)
        do {
            try store.update { $0.accounts.append(account) }
        } catch {
            try? WorkspaceKeychain.remove(account.id)
            throw error
        }
    }

    func quota(for account: WorkspaceAccount) async throws -> [WorkspaceQuota] {
        switch account.credential {
        case .codeBuddyToken:
            let token = try WorkspaceKeychain.read(account.id)
            let host = account.region == "cn" ? "www.codebuddy.cn" : "www.codebuddy.ai"
            let date = DateFormatter()
            date.locale = Locale(identifier: "en_US_POSIX")
            date.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let now = Date()
            let end = Calendar.current.date(byAdding: .year, value: 100, to: now) ?? now
            let body: [String: Any] = [
                "PageNumber": 1, "PageSize": 100, "ProductCode": "p_tcaca", "Status": [0, 3],
                "PackageEndTimeRangeBegin": date.string(from: now), "PackageEndTimeRangeEnd": date.string(from: end),
            ]
            var headers = [String: String]()
            headers["X-User-Id"] = account.userID
            headers["X-Enterprise-Id"] = account.enterpriseID
            headers["X-Tenant-Id"] = account.enterpriseID
            headers["X-Domain"] = account.domain
            if account.enterpriseID != nil {
                let url = URL(string: "https://\(host)/v2/billing/meter/get-enterprise-user-usage")!
                return try Self.parseCodeBuddy(await Self.post(url, token: token, body: [:], headers: headers))
            }
            let url = URL(string: "https://\(host)/v2/billing/meter/get-user-resource")!
            return try Self.parseCodeBuddy(await Self.post(url, token: token, body: body, headers: headers))
        case .geminiLogin:
            let file = try store.accountHome(account.id).appendingPathComponent(".gemini/oauth_creds.json")
            let auth = try Self.object(WorkspaceStore.readImport(file))
            guard let token = auth["access_token"] as? String else { throw WorkspaceError.missingCredential }
            let secret = try WorkspaceKeychain.normalizedSecret(token)
            var project = account.projectID
            if project == nil {
                let environment = ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]
                let data = try await Self.post(Self.codeAssist.appendingPathComponent("v1internal:loadCodeAssist"),
                                               token: secret, body: ["metadata": environment, "mode": "HEALTH_CHECK"])
                project = Self.identifier(try Self.object(data)["cloudaicompanionProject"])
            }
            guard let project else { throw WorkspaceError.noQuota }
            let data = try await Self.post(Self.codeAssist.appendingPathComponent("v1internal:retrieveUserQuota"),
                                           token: secret, body: ["project": project])
            return try Self.parseGemini(data)
        default:
            throw WorkspaceError.noQuota
        }
    }

    static func parseGemini(_ data: Data) throws -> [WorkspaceQuota] {
        let root = try object(data)
        let buckets = root["buckets"] as? [[String: Any]] ?? []
        let quotas: [WorkspaceQuota] = buckets.enumerated().compactMap { index, bucket in
            guard let model = identifier(bucket["modelId"]),
                  let remaining = number(bucket["remainingFraction"]), (0...1).contains(remaining) else { return nil }
            let unit = bucket["tokenType"] as? String
            let detail = number(bucket["remainingAmount"]).map { "\($0.formatted()) \(unit == "REQUESTS" ? "次" : "剩余")" }
            return WorkspaceQuota(id: "\(model):\(index)", title: model, percent: Int((remaining * 100).rounded()),
                                  detail: detail, resetsAt: reset(bucket["resetTime"]))
        }
        guard !quotas.isEmpty else { throw WorkspaceError.noQuota }
        return quotas
    }

    static func parseCodeBuddy(_ data: Data) throws -> [WorkspaceQuota] {
        let root = try object(data)
        if let code = number(root["code"]), code != 0, code != 200 { throw WorkspaceError.noQuota }
        let data = root["data"] as? [String: Any] ?? root
        let inner = data["data"] as? [String: Any] ?? data
        let resourceGroups = [inner, data, root]
        let packages = resourceGroups.lazy.compactMap { layer -> [[String: Any]]? in
            let response = layer["Response"] as? [String: Any]
            let accountData = response?["Data"] as? [String: Any]
            let rows = layer["resources"] as? [[String: Any]] ?? accountData?["Accounts"] as? [[String: Any]]
            return rows?.isEmpty == false ? rows : nil
        }.first ?? [inner]
        let rows: [WorkspaceQuota] = packages.enumerated().compactMap { index, package in
            let total = number(package["CycleCapacitySizePrecise"] ?? package["total"] ?? package["limit_num"] ?? package["limitNum"])
            let used = number(package["used_num"] ?? package["usedNum"] ?? package["credit"])
            let remaining = number(package["CycleCapacityRemainPrecise"] ?? package["remaining"] ?? package["remain"])
                ?? total.flatMap { size in used.map { max(0, size - $0) } }
            let unlimited = total == -1 || package["Unlimited"] as? Bool == true || package["unlimited"] as? Bool == true
            guard unlimited || remaining != nil else { return nil }
            let name = (package["PackageName"] ?? package["name"] ?? package["package_name"]) as? String ?? "Credits"
            let ratio = total.flatMap { size in
                size > 0 ? remaining.map { Int((min(1, max(0, $0 / size)) * 100).rounded()) } : nil
            }
            let detail = unlimited ? "不限量" : remaining.map { "\($0.formatted()) Credits" }
            let time = reset(package["CycleResetTime"] ?? package["cycle_reset_time"] ?? package["DeductionEndTime"]
                             ?? package["ExpiredTime"] ?? package["expire_at"])
            return WorkspaceQuota(id: "codebuddy:\(index)", title: String(name.prefix(96)), percent: ratio,
                                  detail: detail, resetsAt: time)
        }
        guard !rows.isEmpty else { throw WorkspaceError.noQuota }
        return rows
    }

    private static func post(_ url: URL, token: String, body: [String: Any], headers: [String: String] = [:]) async throws -> Data {
        var request = QuotaHTTP.request(to: url, token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw WorkspaceError.unauthorized }
        guard (200..<300).contains(status), data.count <= 2 * 1_024 * 1_024 else { throw WorkspaceError.quotaRequest(status) }
        return data
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        let result = try JSONSerialization.jsonObject(with: data)
        if let fields = result as? [String: Any] { return fields }
        if let records = result as? [[String: Any]], records.count == 1, let record = records.first { return record }
        throw WorkspaceError.invalidAccountFile
    }

    private static func identifier(_ value: Any?) -> String? {
        let value = (value as? String) ?? (value as? NSNumber)?.stringValue
        guard let value, !value.isEmpty, value.utf8.count <= 256,
              value.utf8.allSatisfy({ (33...126).contains($0) }) else { return nil }
        return value
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let result = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        return result.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func reset(_ value: Any?) -> Date? {
        if let text = value as? String, let parsed = QuotaHTTP.resetDate(text) { return parsed }
        guard let unix = number(value), unix > 0 else { return nil }
        return Date(timeIntervalSince1970: unix > 100_000_000_000 ? unix / 1_000 : unix)
    }
}
