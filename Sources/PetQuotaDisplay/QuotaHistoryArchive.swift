import Darwin
import Foundation
import QuotaCore

struct QuotaHistoryArchive {
    struct State {
        var isEnabled = false
        var histories: [QuotaHistoryContext: [QuotaSnapshot]] = [:]
    }

    static let local = QuotaHistoryArchive(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/PetQuotaDisplay/QuotaHistory", isDirectory: true),
        retention: { QuotaHistoryRetention.load() })

    let directory: URL
    private let retention: () -> QuotaHistoryRetention
    private var archiveURL: URL { directory.appendingPathComponent("history.json") }

    init(directory: URL, retention: @escaping () -> QuotaHistoryRetention = { .standard }) {
        self.directory = directory
        self.retention = retention
    }

    func load() throws -> State {
        try load(capacity: retention().rawValue)
    }

    private func load(capacity: Int) throws -> State {
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
            state.histories[context] = QuotaReadingHistory.merged(state.histories[context] ?? [], with: valid, capacity: capacity)
        }
        return state
    }

    func setEnabled(_ enabled: Bool, initial: [QuotaHistoryContext: [QuotaSnapshot]] = [:]) throws {
        try withLock {
            guard enabled else {
                try save(State())
                return
            }
            let capacity = retention().rawValue
            var state = try load(capacity: capacity)
            state.isEnabled = true
            for (context, readings) in initial where !readings.isEmpty {
                state.histories[context] = QuotaReadingHistory.merged(state.histories[context] ?? [], with: readings,
                                                                     capacity: capacity)
            }
            try save(state)
        }
    }

    @discardableResult
    func update(_ snapshots: [QuotaHistoryContext: QuotaSnapshot?]) throws -> Bool {
        try withLock {
            let capacity = retention().rawValue
            var state = try load(capacity: capacity)
            guard state.isEnabled else { return false }
            for (context, latest) in snapshots {
                if let latest {
                    state.histories[context] = QuotaReadingHistory.merged(state.histories[context] ?? [], with: [latest],
                                                                         capacity: capacity)
                } else {
                    state.histories.removeValue(forKey: context)
                }
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

    func clearScope(_ scope: QuotaHistoryContext) throws -> Bool {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else { return false }
        return try withLock {
            var state = try load()
            guard state.isEnabled else { return false }
            let before = state.histories.count
            state.histories = state.histories.filter { $0.key.primary != scope.primary }
            if state.histories.count != before { try save(state) }
            return true
        }
    }

    func mergeImported(_ imported: [QuotaHistoryContext: [QuotaSnapshot]]) throws -> Bool {
        try withLock {
            let capacity = retention().rawValue
            var state = try load(capacity: capacity)
            guard state.isEnabled else { return false }
            for (context, readings) in imported {
                state.histories[context] = QuotaReadingHistory.merged(state.histories[context] ?? [], with: readings,
                                                                     keepingExisting: true, capacity: capacity)
            }
            try save(state)
            return true
        }
    }

    func applyRetention() throws {
        try withLock {
            let state = try load()
            if state.isEnabled { try save(state) }
        }
    }

    func export(for context: QuotaHistoryContext, selecting period: String? = nil,
                since: Date? = nil, until: Date? = nil, range: QuotaHistorySeries.TimeRange? = nil,
                limit: Int? = nil) throws -> QuotaHistoryExport {
        try export(for: context, in: loadEnabled(), selecting: period, since: since, until: until, range: range, limit: limit)
    }

    func exportBatch(for contexts: [QuotaHistoryContext], selecting period: String?,
                     since: Date?, until: Date?, range: QuotaHistorySeries.TimeRange? = nil,
                     limit: Int?, includesModels: Bool = false) throws -> QuotaHistoryBatchExport {
        let state = try loadEnabled()
        let scopes = contexts.flatMap { context -> [QuotaHistoryContext] in
            guard includesModels, context.provider == .codex, context.account != nil else { return [context] }
            let models = state.histories.keys.filter { $0.primary == context && $0.modelID != nil }
                .sorted { ($0.modelID ?? "") < ($1.modelID ?? "") }
            return [context] + models
        }
        let sources = scopes.map {
            export(for: $0, in: state, selecting: period, since: since, until: until, range: range, limit: limit)
        }
        return QuotaHistoryBatchExport(sources: sources)
    }

    private func export(for context: QuotaHistoryContext, in state: State, selecting period: String?,
                        since: Date?, until: Date?, range: QuotaHistorySeries.TimeRange?, limit: Int?) -> QuotaHistoryExport {
        let history = state.histories[context] ?? []
        let available = until.map { end in history.filter { $0.fetchedAt <= end } } ?? history
        let cutoff = range?.cutoff(relativeTo: available.last?.fetchedAt)
        let filtered = available.filter { sample in
            (since.map { sample.fetchedAt >= $0 } ?? true) && (cutoff.map { sample.fetchedAt >= $0 } ?? true)
        }
        return QuotaHistoryExport(provider: context.provider, snapshots: filtered, modelID: context.modelID,
                                  selecting: period, limit: limit)
    }

    func modelCatalog(for account: CodexAccountSlot) throws -> CodexModelCatalog {
        CodexModelCatalog(account: account, histories: try loadEnabled().histories)
    }

    private func loadEnabled() throws -> State {
        let state = try load()
        guard state.isEnabled else { throw Failure.notEnabled }
        return state
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
