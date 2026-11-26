import Darwin
import Foundation
import QuotaCore

final class CodexCLIProcessMonitor {
    var onRunningStateChanged: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "com.petquotadisplay.cli-monitor", qos: .utility)
    private let readSnapshot: () -> [ProcessRecord]?
    private var timer: DispatchSourceTimer?
    private var timerID: UUID?
    private var lastRunningState: Bool?

    init(readSnapshot: @escaping () -> [ProcessRecord]? = CodexCLIProcessMonitor.processSnapshot) {
        self.readSnapshot = readSnapshot
    }

    func start() {
        guard timer == nil else { return }
        let id = UUID()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(3), leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.scan(timerID: id) }
        timerID = id
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timerID = nil
        lastRunningState = nil
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private func scan(timerID: UUID) {
        guard let records = readSnapshot() else { return }
        let isRunning = CodexProcessClassifier.containsInteractiveCLI(
            in: records,
            monitorPID: ProcessInfo.processInfo.processIdentifier
        )
        DispatchQueue.main.async { [weak self] in
            guard let self, self.timerID == timerID, isRunning != self.lastRunningState else { return }
            self.lastRunningState = isRunning
            self.onRunningStateChanged?(isRunning)
        }
    }

    private static func processSnapshot() -> [ProcessRecord]? {
        let estimatedCount = max(256, Int(proc_listallpids(nil, 0)) + 64)
        var pids = [pid_t](repeating: 0, count: estimatedCount)
        let bytes = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let actualCount = pids.withUnsafeMutableBufferPointer { buffer in
            Int(proc_listallpids(buffer.baseAddress, bytes))
        }
        guard actualCount > 0 else { return nil }

        let user = getuid()
        return pids.prefix(min(actualCount, pids.count)).compactMap { pid in
            guard pid > 0,
                  let parentPID = parentPID(of: pid, ownedBy: user),
                  let path = executablePath(of: pid) else { return nil }
            return ProcessRecord(pid: pid, parentPID: parentPID, executablePath: path)
        }
    }

    private static func parentPID(of pid: pid_t, ownedBy user: uid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let actualSize = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, expectedSize)
        }
        guard actualSize == expectedSize, info.pbi_ruid == user else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
