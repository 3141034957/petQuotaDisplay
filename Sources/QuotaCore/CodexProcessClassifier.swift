import Foundation

public struct ProcessRecord: Equatable {
    public let pid: Int32
    public let parentPID: Int32
    public let executablePath: String

    public init(pid: Int32, parentPID: Int32, executablePath: String) {
        self.pid = pid
        self.parentPID = parentPID
        self.executablePath = executablePath
    }
}

public enum CodexProcessClassifier {
    public static func containsInteractiveCLI(
        in records: [ProcessRecord],
        monitorPID: Int32
    ) -> Bool {
        let recordsByPID = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) })
        return records.contains { record in
            guard isCodexExecutable(record.executablePath) else { return false }
            return !hasExcludedAncestor(
                startingAt: record,
                recordsByPID: recordsByPID,
                monitorPID: monitorPID
            )
        }
    }

    private static func isCodexExecutable(_ path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent.lowercased() == "codex"
    }

    private static func hasExcludedAncestor(
        startingAt record: ProcessRecord,
        recordsByPID: [Int32: ProcessRecord],
        monitorPID: Int32
    ) -> Bool {
        var current: ProcessRecord? = record
        var visited = Set<Int32>()

        while let process = current, visited.insert(process.pid).inserted {
            if process.pid == monitorPID { return true }
            if process.executablePath.contains("/ChatGPT.app/") { return true }
            guard process.parentPID > 1 else { return false }
            current = recordsByPID[process.parentPID]
        }
        return false
    }
}
