import Foundation
import UserNotifications

final class QuotaNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static var isSupported: Bool {
        Bundle.main.bundleIdentifier == "com.erenshwang.petquotadisplay" && Bundle.main.bundleURL.pathExtension == "app"
    }

    private let center: UNUserNotificationCenter

    override init() {
        center = .current()
        super.init()
        center.delegate = self
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

    func post(provider: QuotaProvider, events: [QuotaLowReminder.Event], completion: @escaping (Error?) -> Void) {
        let content = Self.content(provider: provider, events: events)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    static func isAuthorizationError(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == UNErrorDomain && value.code == UNError.Code.notificationsNotAllowed.rawValue
    }

    static func content(provider: QuotaProvider, events: [QuotaLowReminder.Event]) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "\(provider.title) 额度提醒"
        content.body = events.map { "\($0.period.title)剩余 \($0.remainingPercent)%" }.joined(separator: "，")
        return content
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
