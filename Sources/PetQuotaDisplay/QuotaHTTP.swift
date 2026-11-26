import Foundation

enum QuotaHTTP {
    private static let timeout: TimeInterval = 20

    static func makeSession(localOnly: Bool = false) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        if localOnly {
            configuration.connectionProxyDictionary = ["HTTPEnable": false, "HTTPSEnable": false, "SOCKSEnable": false]
        }
        return URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }

    static func request(to url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func resetDate(_ value: String) -> Date? {
        (try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(value, strategy: Date.ISO8601FormatStyle()))
    }

    static func retryDate(_ header: String?, now: Date = Date()) -> Date? {
        guard let value = header?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let seconds = Int(value) {
            return seconds > 0 ? now.addingTimeInterval(TimeInterval(seconds)) : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        guard let date = formatter.date(from: value), date > now else { return nil }
        return date
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
