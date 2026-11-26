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
}
