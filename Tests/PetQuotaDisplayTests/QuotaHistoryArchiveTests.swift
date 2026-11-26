import QuotaCore
import XCTest
@testable import PetQuotaDisplay

final class QuotaHistoryArchiveTests: XCTestCase {
    func testCustomRetentionKeepsRecentRecordsAndTrimsTheOnDiskArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var retention = QuotaHistoryRetention.extended
        let archive = QuotaHistoryArchive(directory: root, retention: { retention })
        let context = QuotaHistoryContext(provider: .gemini, account: nil)
        let captures = (1...180).map { snapshot(at: Double($0)) }
        try archive.setEnabled(true, initial: [context: captures])
        XCTAssertEqual(try archive.load().histories[context]?.count, 180)
        var memory = QuotaReadingHistory(capacity: retention.rawValue)
        for capture in captures { memory.record(capture) }
        XCTAssertEqual(memory.readings.count, 180)
        retention = .standard
        memory.setCapacity(retention.rawValue)
        try archive.applyRetention()
        retention = .large
        let stored = try archive.load().histories[context]
        XCTAssertEqual(stored, memory.readings)
        XCTAssertEqual(stored?.first?.fetchedAt, captures[60].fetchedAt)
    }

    func testModelArchivePreservesExistingPrimaryHistoryAndMarksExports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = QuotaHistoryArchive(directory: root)
        let account = try XCTUnwrap(CodexAccountSlot(rawValue: UUID().uuidString))
        let main = QuotaHistoryContext(provider: .codex, account: account)
        let model = QuotaHistoryContext(provider: .codex, account: account, modelID: "extra")
        let original = snapshot(at: 100)
        let additional = snapshot(at: 200)

        try archive.setEnabled(true, initial: [main: [original]])
        XCTAssertEqual(try archive.load().histories[main], [original])
        try archive.update([model: additional])
        XCTAssertEqual(try archive.load().histories, [main: [original], model: [additional]])

        let export = try archive.export(for: model)
        XCTAssertEqual(export.modelID, "extra")
        let csv = try export.render(as: .csv)
        XCTAssertTrue(csv.contains("resetsAt,modelID\n"))
        XCTAssertTrue(csv.hasSuffix(",extra"))
        XCTAssertNil(try archive.export(for: main).modelID)
        XCTAssertEqual(try archive.modelCatalog(for: account).models.map(\.id), ["codex", "extra"])
        let otherAccount = try XCTUnwrap(CodexAccountSlot(rawValue: UUID().uuidString))
        XCTAssertTrue(try archive.modelCatalog(for: otherAccount).models.isEmpty)
    }

    func testResetCanReplaceAnUnreadableArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = QuotaHistoryArchive(directory: root)
        XCTAssertEqual(QuotaDiagnostics.HistoryStatus(archive: archive, retention: .standard).state, .disabled)
        try archive.setEnabled(true)
        let enabled = QuotaDiagnostics.HistoryStatus(archive: archive, retention: .standard)
        XCTAssertEqual(enabled.state, .enabled)
        XCTAssertEqual(enabled.readingCount, 0)
        try Data("invalid JSON".utf8).write(to: root.appendingPathComponent("history.json"))
        XCTAssertThrowsError(try archive.load())
        XCTAssertEqual(QuotaDiagnostics.HistoryStatus(archive: archive, retention: .standard).state, .unreadable)
        try archive.setEnabled(false)
        XCTAssertFalse(try archive.load().isEnabled)
        try archive.setEnabled(true)
        XCTAssertTrue(try archive.load().isEnabled)
    }

    func testHistoryLimitUsesTheNewestMatchingReadings() {
        let older = snapshot(at: 10)
        let matching = snapshot(at: 20)
        let otherPeriod = QuotaSnapshot(planType: nil, fiveHour: QuotaWindow(usedPercent: 90, resetsAt: nil), weekly: nil,
                                        fetchedAt: Date(timeIntervalSince1970: 30))
        let report = QuotaHistoryExport(provider: .gemini, snapshots: [older, matching, otherPeriod], selecting: "weekly", limit: 1)
        XCTAssertEqual(report.readings.map(\.fetchedAt), [matching.fetchedAt])
    }

    func testHistoryRelativeRangeEndsAtTheLastCaptureBeforeTheUpperBound() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = QuotaHistoryArchive(directory: root)
        let context = QuotaHistoryContext(provider: .gemini, account: nil)
        try archive.setEnabled(true, initial: [context: [snapshot(at: 100), snapshot(at: 1_000), snapshot(at: 2_000)]])
        let export = try archive.export(for: context, until: Date(timeIntervalSince1970: 1_500), range: .quarterHour)
        XCTAssertEqual(export.readings.map { $0.fetchedAt.timeIntervalSince1970 }, [100, 1_000])
        let latest = try archive.export(for: context, range: .quarterHour)
        XCTAssertEqual(latest.readings.map { $0.fetchedAt.timeIntervalSince1970 }, [2_000])
    }

    func testHistoryStatisticsExcludeMissingPeriodsAndUseFilteredReadings() throws {
        let start = snapshot(at: 10)
        let recent = QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 50, resetsAt: nil),
                                   fetchedAt: Date(timeIntervalSince1970: 20))
        let otherPeriod = QuotaSnapshot(planType: nil, fiveHour: QuotaWindow(usedPercent: 90, resetsAt: nil),
                                        weekly: nil, fetchedAt: Date(timeIntervalSince1970: 30))
        let export = QuotaHistoryExport(provider: .gemini, snapshots: [start, recent, otherPeriod], selecting: "weekly")
        let statistics = QuotaHistoryStatistics([export])
        XCTAssertEqual(statistics.sources.first?.readingCount, 2)
        XCTAssertEqual(statistics.sources.first?.periods.map(\.id), ["weekly"])
        XCTAssertTrue(try statistics.render(as: .csv).hasSuffix("gemini,,weekly,2,50,80,50"))
    }

    func testPortableHistoryReadsSingleAndBatchExportsAndRejectsOtherVersions() throws {
        let reading = snapshot(at: 65)
        let export = QuotaHistoryExport(provider: .codex, snapshots: [reading], modelID: "extra")
        let single = try QuotaPortableHistory(data: Data(export.render(as: .json).utf8))
        XCTAssertEqual(single.sources.first?.modelID, "extra")
        XCTAssertEqual(single.sources.first?.readings.first?.snapshot, reading)
        let batch = try QuotaHistoryBatchExport(sources: [export]).render(as: .json)
        XCTAssertEqual(try QuotaPortableHistory(data: Data(batch.utf8)).sources.count, 1)
        let unsupported = Data(#"{"schemaVersion":9,"provider":"codex","readings":[]}"#.utf8)
        XCTAssertThrowsError(try QuotaPortableHistory(data: unsupported))
    }

    func testBatchHistoryPreservesSourceOrderFiltersAndAccountScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = QuotaHistoryArchive(directory: root)
        let account = try XCTUnwrap(CodexAccountSlot(rawValue: UUID().uuidString))
        let another = try XCTUnwrap(CodexAccountSlot(rawValue: UUID().uuidString))
        let selected = QuotaHistoryContext(provider: .codex, account: account)
        let model = QuotaHistoryContext(provider: .codex, account: account, modelID: "extra")
        let gemini = QuotaHistoryContext(provider: .gemini, account: nil)
        try archive.setEnabled(true, initial: [
            selected: [snapshot(at: 10), snapshot(at: 11)],
            model: [snapshot(at: 15)],
            QuotaHistoryContext(provider: .codex, account: another): [snapshot(at: 12)],
            QuotaHistoryContext(provider: .codex, account: another, modelID: "other"): [snapshot(at: 16)],
            gemini: [snapshot(at: 13), snapshot(at: 14)],
        ])
        let report = try archive.exportBatch(for: [gemini, selected], selecting: "weekly",
                                             since: nil, until: nil, limit: 1)
        XCTAssertEqual(report.sources.map(\.provider), ["gemini", "codex"])
        XCTAssertEqual(report.sources.map { $0.readings.first?.fetchedAt }, [snapshot(at: 14).fetchedAt, snapshot(at: 11).fetchedAt])
        XCTAssertEqual(try report.render(as: .csv).split(separator: "\n").count, 3)
        let withModels = try archive.exportBatch(for: [gemini, selected], selecting: nil,
                                                 since: nil, until: nil, limit: 1, includesModels: true)
        XCTAssertEqual(withModels.sources.map(\.modelID), [nil, nil, "extra"])
        XCTAssertTrue(try withModels.render(as: .csv).hasSuffix(",extra"))
    }

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
        XCTAssertTrue(try exported.render(as: .text).contains("本周剩余 80%"))
        XCTAssertTrue(try exported.render(as: .csv).contains("gemini,weekly,1970-01-01T00:01:40Z,80,"))
        XCTAssertEqual(try archive.export(for: context, selecting: "lowestRemaining").readings.first?.periods.first?.id, "weekly")
        XCTAssertTrue(try archive.export(for: context, selecting: "monthly").readings.isEmpty)
        XCTAssertEqual(try archive.export(for: context, since: original.fetchedAt, until: original.fetchedAt).readings.count, 1)
        XCTAssertTrue(try archive.export(for: context, since: original.fetchedAt.addingTimeInterval(1)).readings.isEmpty)
        XCTAssertTrue(try archive.export(for: QuotaHistoryContext(provider: .kimiCode, account: nil)).readings.isEmpty)

        try archive.setEnabled(false)
        XCTAssertFalse(try archive.update([context: snapshot(at: 101)]))
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
                try archive.update([index.isMultiple(of: 2) ? first : second: snapshot(at: Double(index))])
            } catch {
                XCTFail("Archive write failed: \(error)")
            }
        }
        let restored = try archive.load().histories
        XCTAssertEqual(restored[first]?.count, 10)
        XCTAssertEqual(restored[second]?.count, 10)
        try archive.update([first: nil, second: snapshot(at: 20)])
        XCTAssertNil(try archive.load().histories[first])
        XCTAssertEqual(try archive.load().histories[second]?.count, 11)
        try archive.clear()
        XCTAssertTrue(try archive.load().isEnabled)
        XCTAssertTrue(try archive.load().histories.isEmpty)
    }

    private func snapshot(at seconds: TimeInterval) -> QuotaSnapshot {
        QuotaSnapshot(planType: nil, fiveHour: nil, weekly: QuotaWindow(usedPercent: 20, resetsAt: nil),
                      fetchedAt: Date(timeIntervalSince1970: seconds))
    }
}
