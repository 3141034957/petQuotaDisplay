import QuotaCore

protocol PollingQuotaClient: AnyObject {
    var onRefreshing: (() -> Void)? { get set }
    var onResult: ((Result<QuotaSnapshot, Error>) -> Void)? { get set }
    func refresh()
    func stop()
}
