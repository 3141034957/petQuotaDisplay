import Foundation

struct QuotaPortableHistory {
    private static let maximumFileSize = 64 * 1_024 * 1_024
    let sources: [QuotaHistoryExport]

    static func read(from url: URL) throws -> Self {
        let file = url.resolvingSymlinksInPath()
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw Failure.invalidFile }
        guard values.fileSize.map({ $0 <= maximumFileSize }) ?? true else { throw Failure.tooLarge }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
        guard data.count <= maximumFileSize else { throw Failure.tooLarge }
        return try Self(data: data)
    }

    init(data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let groups: [Group]
        if let batch = try? decoder.decode(Batch.self, from: data) {
            groups = batch.sources
        } else if let single = try? decoder.decode(Group.self, from: data) {
            groups = [single]
        } else {
            throw Failure.invalidFile
        }

        sources = try groups.map { group in
            guard group.schemaVersion == 1 else { throw Failure.unsupportedVersion }
            guard let provider = QuotaProvider(rawValue: group.provider) else { throw Failure.invalidFile }
            if let modelID = group.modelID {
                guard provider == .codex, !modelID.isEmpty, modelID != "codex" else { throw Failure.invalidFile }
            }
            let snapshots = group.readings.compactMap(\.snapshot)
            guard snapshots.count == group.readings.count else { throw Failure.invalidFile }
            return QuotaHistoryExport(provider: provider, snapshots: snapshots.sorted { $0.fetchedAt < $1.fetchedAt },
                                      modelID: group.modelID)
        }
    }

    private struct Batch: Decodable {
        let sources: [Group]
    }

    private struct Group: Decodable {
        let schemaVersion: Int
        let provider: String
        let modelID: String?
        let readings: [QuotaHistoryRecord]
    }

    private enum Failure: LocalizedError {
        case invalidFile, unsupportedVersion, tooLarge

        var errorDescription: String? {
            switch self {
            case .invalidFile: return "无法读取此额度历史 JSON，请选择应用导出的采集记录文件。"
            case .unsupportedVersion: return "此额度历史文件使用了当前应用无法读取的版本。"
            case .tooLarge: return "额度历史 JSON 文件超过 64 MiB。"
            }
        }
    }
}
