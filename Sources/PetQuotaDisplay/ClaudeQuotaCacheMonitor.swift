import Darwin
import Foundation

final class ClaudeQuotaCacheMonitor {
    private let directory: URL
    private var source: DispatchSourceFileSystemObject?
    private var pendingRefresh: DispatchWorkItem?
    private var generation: UUID?
    var onChange: (() -> Void)?

    init(directory: URL) {
        self.directory = directory
    }

    deinit { stop() }

    func start() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        let generation = UUID()
        self.generation = generation
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                                eventMask: [.write, .rename, .delete], queue: .main)
        watcher.setCancelHandler { close(descriptor) }
        watcher.setRegistrationHandler { [weak self] in
            guard let self, self.generation == generation else { return }
            self.scheduleRefresh()
        }
        watcher.setEventHandler { [weak self] in
            guard let self, self.generation == generation, let events = self.source?.data else { return }
            if events.contains(.rename) || events.contains(.delete) { self.stop() }
            self.scheduleRefresh()
        }
        source = watcher
        watcher.activate()
    }

    func stop() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        source?.cancel()
        source = nil
        generation = nil
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingRefresh = nil
            self?.onChange?()
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}
