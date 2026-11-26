import QuotaCore
import XCTest
@testable import PetQuotaDisplay

final class QuotaHistoryArchiveTests: XCTestCase {
    func testArchiveRequiresOptInAndCanBeDisabled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = QuotaHistoryArchive(directory: root)
        let context = QuotaHistoryContext(provider: .gemini, account: nil)
        let original = snapshot(at: 100.25)
        XCTAssertFalse(try archive.load().isEnabled)
        XCTAssertThrowsError(try archive.export(for: context))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        try archive.setEnabled(true, initial: [context: [original]])
        XCTAssertTrue(try archive.load().isEnabled)
        XCTAssertEqual(try archive.load().histories[context], [original])
        let exported = try archive.export(for: context)
        XCTAssertEqual(exported.provider, "gemini")
        XCTAssertEqual(exported.readings.first?.snapshot, original)
        XCTAssertEqual(try archive.export(for: context, selecting: "lowestRemaining").readings.first?.periods.first?.id, "weekly")
        XCTAssertTrue(try archive.export(for: context, selecting: "monthly").readings.isEmpty)
        XCTAssertTrue(try archive.export(for: QuotaHistoryContext(provider: .kimiCode, account: nil)).readings.isEmpty)

        try archive.setEnabled(false)
        try archive.update(context, latest: snapshot(at: 101))
        XCTAssertFalse(try archive.load().isEnabled)
        XCTAssertTrue(try archive.load().histories.isEmpty)
    }

    func testSimultaneousWritersMergeAndScopedRemovalPreservesOthers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = QuotaHistoryArchive(directory: root)
        let first = QuotaHistoryContext(provider: .gemini, account: nil)
        let second = QuotaHistoryContext(provider: .kimiCode, account: nil)
        try archive.setEnabled(true)
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            do {
                try archive.update(index.isMultiple(of: 2) ? first : second, latest: snapshot(at: Double(index)))
            } catch {
                XCTFail("Archive write failed: \(error)")
            }
        }
        let restored = try archive.load().histories
        XCTAssertEqual(restored[first]?.count, 10)
        XCTAssertEqual(restored[second]?.count, 10)
        try archive.update(first, latest: nil)
        XCTAssertNil(try archive.load().histories[first])
        XCTAssertEqual(try archive.load().histories[second]?.count, 10)
        try archive.clear()
        XCTAssertTrue(try archive.load().isEnabled)
        XCTAssertTrue(try archive.load().histories.isEmpty)
    }

    private func snapshot(at seconds: TimeInterval) -> QuotaSnapshot {
        QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 20, resetsAt: nil),
                      fetchedAt: Date(timeIntervalSince1970: seconds))
    }
}
