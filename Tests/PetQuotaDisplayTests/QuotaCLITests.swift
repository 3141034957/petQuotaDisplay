import XCTest
@testable import PetQuotaDisplay

final class QuotaCLITests: XCTestCase {
    func testSearchSkipsDirectoryNamedLikeExecutable() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fakeCommand = directory.appendingPathComponent("sh")
        try files.createDirectory(at: fakeCommand, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }

        XCTAssertEqual(QuotaCLI.find("sh", override: "TEST_CLI", environment: ["PATH": "\(directory.path):/bin"])?.path, "/bin/sh")
        XCTAssertNil(QuotaCLI.find("sh", override: "TEST_CLI", environment: ["TEST_CLI": fakeCommand.path]))
        XCTAssertNil(QuotaCLI.find("sh", override: "TEST_CLI", environment: ["TEST_CLI": "bin/sh"]))
    }

    func testCodexRunsNativeExecutableDirectlyAndUsesNodeForJavaScriptWrapper() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        for name in ["codex.js", "codex-native", "node"] {
            let path = directory.appendingPathComponent(name).path
            XCTAssertTrue(files.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o700]))
        }
        let wrapper = directory.appendingPathComponent("codex")
        try files.createSymbolicLink(atPath: wrapper.path, withDestinationPath: "codex.js")

        let launch = CodexQuotaClient.resolveCodexLaunch(environment: ["PATH": directory.path])
        XCTAssertEqual(launch?.executable, directory.appendingPathComponent("node").path)
        XCTAssertEqual(launch?.arguments, [wrapper.path])

        let native = directory.appendingPathComponent("codex-native").path
        let override = CodexQuotaClient.resolveCodexLaunch(environment: ["CODEX_CLI_PATH": native])
        XCTAssertEqual(override?.executable, native)
        XCTAssertEqual(override?.arguments, [])
        XCTAssertNil(CodexQuotaClient.resolveCodexLaunch(environment: ["CODEX_CLI_PATH": directory.path]))
    }
}
