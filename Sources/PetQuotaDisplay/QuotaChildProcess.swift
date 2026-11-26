import Darwin
import Foundation

enum QuotaChildProcess {
    private static let pendingTerminations = DispatchGroup()

    static func terminate(_ process: Process?, afterExit: @escaping () -> Void = {}) {
        guard let process, process.isRunning else {
            afterExit()
            return
        }
        pendingTerminations.enter()
        process.terminate()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            afterExit()
            pendingTerminations.leave()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    static func waitForTerminations() {
        _ = pendingTerminations.wait(timeout: .now() + 2)
    }
}
