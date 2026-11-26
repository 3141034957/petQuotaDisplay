import QuotaCore
import XCTest
@testable import PetQuotaDisplay

final class CodexCLIProcessMonitorTests: XCTestCase {
    func testStoppedMonitorIgnoresQueuedResultAndCanStartAgain() {
        let scanned = DispatchSemaphore(value: 0)
        let monitor = CodexCLIProcessMonitor(readSnapshot: {
            scanned.signal()
            return [ProcessRecord(pid: Int32.max, parentPID: 1, executablePath: "/test/codex")]
        })
        defer { monitor.stop() }

        let ignored = expectation(description: "stopped monitor must not emit")
        ignored.isInverted = true
        monitor.onRunningStateChanged = { _ in ignored.fulfill() }
        monitor.start()
        XCTAssertEqual(scanned.wait(timeout: .now() + 3), .success)
        monitor.stop()
        wait(for: [ignored], timeout: 0.1)

        let delivered = expectation(description: "new monitor emits current state")
        monitor.onRunningStateChanged = { running in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(running)
            delivered.fulfill()
        }
        monitor.start()
        wait(for: [delivered], timeout: 3)
    }
}
