import Darwin
import Foundation

enum QuotaChildProcess {
    static func terminate(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
