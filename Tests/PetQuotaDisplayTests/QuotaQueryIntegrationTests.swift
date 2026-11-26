import Darwin
import Foundation
import XCTest

final class QuotaQueryIntegrationTests: XCTestCase {
    func testBatchStartsProvidersTogetherAndKeepsTheResultBeforeDeadline() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let gemini = directory.appendingPathComponent("agy")
        let kimi = directory.appendingPathComponent("kimi")
        let ready = directory.appendingPathComponent("kimi.ready")
        try #"""
        #!/bin/sh
        if [ "$1" = "--version" ]; then
            while [ ! -f "$QUOTA_TEST_READY" ]; do /bin/sleep 0.02; done
            echo "1.1.11"
        else
            echo '{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"buckets":[{"id":"gemini-weekly","remaining_fraction":0.75}]}]}}}'
        fi
        """#.write(to: gemini, atomically: true, encoding: .utf8)
        try #"""
        #!/bin/sh
        printf '%s\n' "$PWD" > "$QUOTA_TEST_READY"
        exec /bin/sleep 6
        """#.write(to: kimi, atomically: true, encoding: .utf8)
        for executable in [gemini, kimi] {
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        let process = Process()
        process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("PetQuotaDisplay")
        process.arguments = ["--query", "--providers", "gemini,kimiCode", "--timeout", "2", "--period", "weekly"]
        var environment = ProcessInfo.processInfo.environment
        environment["ANTIGRAVITY_CLI_PATH"] = gemini.path
        environment["KIMI_CLI_PATH"] = kimi.path
        environment["QUOTA_TEST_READY"] = ready.path
        environment["TMPDIR"] = directory.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output

        let exited = expectation(description: "batch query exited")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        wait(for: [exited], timeout: 5)
        guard !process.isRunning else {
            process.terminate()
            return XCTFail("Batch query did not exit")
        }
        XCTAssertEqual(process.terminationStatus, 1)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sources = try XCTUnwrap(report["sources"] as? [[String: Any]])
        XCTAssertEqual(sources.compactMap { $0["provider"] as? String }, ["gemini", "kimiCode"])
        let quota = try XCTUnwrap(sources.first?["quota"] as? [String: Any])
        let periods = try XCTUnwrap(quota["periods"] as? [[String: Any]])
        XCTAssertEqual(periods.map { $0["remainingPercent"] as? Int }, [75])
        XCTAssertEqual(sources.last?["error"] as? String, "读取额度超时")
        let workspace = try String(contentsOf: ready, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(workspace.isEmpty)
        XCTAssertFalse(files.fileExists(atPath: workspace))
    }

    func testQueryTimeoutReapsAChildThatIgnoresTermination() throws {
        try assertChildReaped(interrupt: false)
    }

    func testInterruptedQueryReapsAChildThatIgnoresTermination() throws {
        try assertChildReaped(interrupt: true)
    }

    private func assertChildReaped(interrupt: Bool) throws {
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
        process.arguments = ["--query", "--provider", "gemini", "--timeout", interrupt ? "20" : "1"]
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
        if interrupt {
            let deadline = Date().addingTimeInterval(2)
            while !files.fileExists(atPath: pidFile.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertTrue(files.fileExists(atPath: pidFile.path))
            XCTAssertEqual(kill(process.processIdentifier, SIGINT), 0)
        }
        wait(for: [exited], timeout: 5)
        guard !process.isRunning else {
            process.terminate()
            return XCTFail("Query did not exit")
        }

        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, interrupt ? 130 : 1)
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if !interrupt { XCTAssertTrue(message.contains("读取额度超时")) }
        let pid = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let processID = try XCTUnwrap(Int32(pid))
        XCTAssertEqual(kill(processID, 0), -1, "The CLI should reap the helper before returning")
        XCTAssertEqual(errno, ESRCH)
    }
}
