import Darwin
import Foundation
import QuotaCore

struct QuotaHistoryArchive {
    struct State {
        var isEnabled = false
        var histories: [QuotaHistoryContext: [QuotaSnapshot]] = [:]
    }

    static let local = QuotaHistoryArchive(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/PetQuotaDisplay/QuotaHistory", isDirectory: true))

    let directory: URL
    private var archiveURL: URL { directory.appendingPathComponent("history.json") }

    func load() throws -> State {
        let data: Data
        do {
            data = try Data(contentsOf: archiveURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return State()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let document = try decoder.decode(Document.self, from: data)
        guard (1...2).contains(document.version) else { throw Failure.unsupportedVersion }
        guard document.enabled else { return State() }

        var state = State(isEnabled: true)
        for entry in document.entries {
            guard let context = entry.context else { continue }
            let valid = entry.readings.compactMap(\.snapshot)
            guard !valid.isEmpty else { continue }
            state.histories[context] = Self.merge(state.histories[context] ?? [], with: valid)
        }
        return state
    }

    func setEnabled(_ enabled: Bool, initial: [QuotaHistoryContext: [QuotaSnapshot]] = [:]) throws {
        try withLock {
            guard enabled else {
                try save(State())
                return
            }
            var state = try load()
            state.isEnabled = true
            for (context, readings) in initial where !readings.isEmpty {
                state.histories[context] = Self.merge(state.histories[context] ?? [], with: readings)
            }
            try save(state)
        }
    }

    @discardableResult
    func update(_ context: QuotaHistoryContext, latest: QuotaSnapshot?) throws -> Bool {
        try withLock {
            var state = try load()
            guard state.isEnabled else { return false }
            if let latest {
                state.histories[context] = Self.merge(state.histories[context] ?? [], with: [latest])
            } else {
                state.histories.removeValue(forKey: context)
            }
            try save(state)
            return true
        }
    }

    func clear() throws {
        try withLock {
            let state = try load()
            if state.isEnabled { try save(State(isEnabled: true)) }
        }
    }

    func export(for context: QuotaHistoryContext, selecting period: String? = nil,
                since: Date? = nil, until: Date? = nil, limit: Int? = nil) throws -> QuotaHistoryExport {
        let state = try load()
        guard state.isEnabled else { throw Failure.notEnabled }
        let filtered = (state.histories[context] ?? []).filter { sample in
            (since.map { sample.fetchedAt >= $0 } ?? true) && (until.map { sample.fetchedAt <= $0 } ?? true)
        }
        return QuotaHistoryExport(provider: context.provider, snapshots: filtered, modelID: context.modelID,
                                  selecting: period, limit: limit)
    }

    private static func merge(_ existing: [QuotaSnapshot], with incoming: [QuotaSnapshot]) -> [QuotaSnapshot] {
        var byDate: [Date: QuotaSnapshot] = [:]
        for snapshot in existing + incoming { byDate[snapshot.fetchedAt] = snapshot }
        return byDate.keys.sorted().suffix(QuotaReadingHistory.maximumReadings).compactMap { byDate[$0] }
    }

    private func save(_ state: State) throws {
        let entries = state.histories.map { Entry(context: $0.key, snapshots: $0.value) }
        let version = entries.contains { $0.modelID != nil } ? 2 : 1
        let document = Document(version: version, enabled: state.isEnabled, entries: entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(document).write(to: archiveURL, options: .atomic)
    }

    private func withLock<Value>(_ work: () throws -> Value) throws -> Value {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lockURL = directory.appendingPathComponent("history.lock")
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        return try work()
    }

    private struct Document: Codable {
        let version: Int
        let enabled: Bool
        let entries: [Entry]
    }

    private struct Entry: Codable {
        let provider: String
        let accountID: String?
        let modelID: String?
        let readings: [QuotaHistoryRecord]

        init(context: QuotaHistoryContext, snapshots: [QuotaSnapshot]) {
            provider = context.provider.rawValue
            accountID = context.account?.rawValue
            modelID = context.modelID
            readings = snapshots.map { QuotaHistoryRecord($0) }
        }

        var context: QuotaHistoryContext? {
            guard let source = QuotaProvider(rawValue: provider) else { return nil }
            if source == .codex {
                guard let accountID, let account = CodexAccountSlot(rawValue: accountID) else { return nil }
                return QuotaHistoryContext(provider: source, account: account, modelID: modelID)
            }
            guard accountID == nil, modelID == nil else { return nil }
            return QuotaHistoryContext(provider: source, account: nil)
        }
    }

    private enum Failure: LocalizedError {
        case unsupportedVersion, notEnabled

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion: return "无法读取此版本的额度历史"
            case .notEnabled: return "请先在悬浮球启用跨启动保留采集记录"
            }
        }
    }
}
