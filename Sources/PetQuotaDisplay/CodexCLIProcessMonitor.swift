import Darwin
import Foundation
import QuotaCore

final class CodexCLIProcessMonitor {
    var onRunningStateChanged: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "com.petquotadisplay.cli-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastRunningState: Bool?

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(3), leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.scan() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private func scan() {
        let records = Self.processSnapshot()
        let isRunning = CodexProcessClassifier.containsInteractiveCLI(
            in: records,
            monitorPID: ProcessInfo.processInfo.processIdentifier
        )
        guard isRunning != lastRunningState else { return }
        lastRunningState = isRunning
        DispatchQueue.main.async { [weak self] in
            self?.onRunningStateChanged?(isRunning)
        }
    }

    private static func processSnapshot() -> [ProcessRecord] {
        let estimatedCount = max(256, Int(proc_listallpids(nil, 0)) + 64)
        var pids = [pid_t](repeating: 0, count: estimatedCount)
        let bytes = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let actualCount = pids.withUnsafeMutableBufferPointer { buffer in
            Int(proc_listallpids(buffer.baseAddress, bytes))
        }
        guard actualCount > 0 else { return [] }

        return pids.prefix(min(actualCount, pids.count)).compactMap { pid in
            guard pid > 0,
                  let parentPID = parentPID(of: pid),
                  let path = executablePath(of: pid) else { return nil }
            return ProcessRecord(pid: pid, parentPID: parentPID, executablePath: path)
        }
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let actualSize = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, expectedSize)
        }
        guard actualSize == expectedSize else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
