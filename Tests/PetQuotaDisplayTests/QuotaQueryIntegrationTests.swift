import Darwin
import Foundation
import XCTest

final class QuotaQueryIntegrationTests: XCTestCase {
    func testQueryTimeoutReapsAChildThatIgnoresTermination() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("agy")
        let pidFile = directory.appendingPathComponent("child.pid")
        try """
        #!/bin/sh
        trap '' TERM
        printf '%s\\n' "$$" > "$QUOTA_TEST_PID_FILE"
        exec /bin/sleep 6
        """.write(to: cli, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)

        let process = Process()
        process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("PetQuotaDisplay")
        process.arguments = ["--query", "--provider", "gemini", "--timeout", "1"]
        var environment = ProcessInfo.processInfo.environment
        environment["ANTIGRAVITY_CLI_PATH"] = cli.path
        environment["QUOTA_TEST_PID_FILE"] = pidFile.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors

        let exited = expectation(description: "headless query exited")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        wait(for: [exited], timeout: 5)
        guard !process.isRunning else {
            process.terminate()
            return XCTFail("Query did not exit")
        }

        XCTAssertEqual(process.terminationStatus, 1)
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(message.contains("读取额度超时"))
        let pid = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let processID = try XCTUnwrap(Int32(pid))
        XCTAssertEqual(kill(processID, 0), -1, "The CLI should reap the helper before returning")
        XCTAssertEqual(errno, ESRCH)
    }
}
