import Foundation

public enum QuotaDisplayState: Equatable {
    case loading
    case loaded(QuotaSnapshot)
    case refreshing(QuotaSnapshot)
    case stale(QuotaSnapshot, String)
    case failed(String)

    public var snapshot: QuotaSnapshot? {
        switch self {
        case .loaded(let snapshot), .refreshing(let snapshot), .stale(let snapshot, _):
            return snapshot
        case .loading, .failed:
            return nil
        }
    }

    public var errorMessage: String? {
        switch self {
        case .stale(_, let message), .failed(let message): return message
        default: return nil
        }
    }

    public var isRefreshing: Bool {
        switch self {
        case .loading, .refreshing: return true
        default: return false
        }
    }

    public mutating func beginRefresh() {
        self = snapshot.map(Self.refreshing) ?? .loading
    }

    public mutating func recordFailure(_ message: String) {
        self = snapshot.map { .stale($0, message) } ?? .failed(message)
    }
}
