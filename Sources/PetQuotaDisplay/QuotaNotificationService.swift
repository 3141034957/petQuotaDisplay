import Foundation
import UserNotifications

final class QuotaNotificationService: NSObject, UNUserNotificationCenterDelegate {
    private static let historyCategory = "quota.history"
    private static let showHistoryAction = "quota.showHistory"
    var onShowHistory: ((QuotaHistoryContext) -> Void)?

    static var isSupported: Bool {
        Bundle.main.bundleIdentifier == "com.erenshwang.petquotadisplay" && Bundle.main.bundleURL.pathExtension == "app"
    }

    private let center: UNUserNotificationCenter

    override init() {
        center = .current()
        super.init()
        center.delegate = self
        let action = UNNotificationAction(identifier: Self.showHistoryAction, title: "查看额度趋势", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.historyCategory, actions: [action],
                                                                  intentIdentifiers: [])])
    }

    func requestAuthorization(completion: @escaping (Bool, Error?) -> Void) {
        center.requestAuthorization(options: [.alert]) { granted, error in
            DispatchQueue.main.async { completion(granted, error) }
        }
    }

    func checkAuthorization(completion: @escaping (Bool) -> Void) {
        center.getNotificationSettings { settings in
            let enabled = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async { completion(enabled) }
        }
    }

    func post(scope: QuotaHistoryContext, events: [QuotaLowReminder.Event], completion: @escaping (Error?) -> Void) {
        let content = Self.content(provider: scope.provider, modelID: scope.modelID, events: events)
        content.categoryIdentifier = Self.historyCategory
        content.userInfo = Self.userInfo(for: scope)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    static func userInfo(for context: QuotaHistoryContext) -> [String: String] {
        var info = ["provider": context.provider.rawValue]
        if let account = context.account { info["account"] = account.rawValue }
        if let modelID = context.modelID { info["modelID"] = modelID }
        return info
    }

    static func historyContext(from info: [AnyHashable: Any]) -> QuotaHistoryContext? {
        guard let raw = info["provider"] as? String, let provider = QuotaProvider(rawValue: raw) else { return nil }
        if provider == .codex {
            let modelID = info["modelID"] as? String
            guard let rawAccount = info["account"] as? String, let account = CodexAccountSlot(rawValue: rawAccount),
                  info["modelID"] == nil || modelID?.isEmpty == false else { return nil }
            return QuotaHistoryContext(provider: provider, account: account, modelID: modelID)
        }
        guard info["account"] == nil, info["modelID"] == nil else { return nil }
        return QuotaHistoryContext(provider: provider, account: nil)
    }

    static func isAuthorizationError(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == UNErrorDomain && value.code == UNError.Code.notificationsNotAllowed.rawValue
    }

    static func content(provider: QuotaProvider, modelID: String? = nil,
                        events: [QuotaLowReminder.Event]) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let source = [provider.title, modelID].compactMap { $0 }.joined(separator: " · ")
        content.title = "\(source) 额度提醒"
        content.body = events.map { "\($0.period.title)剩余 \($0.remainingPercent)%" }.joined(separator: "，")
        return content
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard response.actionIdentifier == Self.showHistoryAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let context = Self.historyContext(from: response.notification.request.content.userInfo) else { return }
        DispatchQueue.main.async { [weak self] in self?.onShowHistory?(context) }
    }
}
