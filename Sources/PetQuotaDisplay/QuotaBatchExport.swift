import Foundation

struct QuotaBatchExport: Encodable {
    struct Source: Encodable {
        let provider: String
        let quota: QuotaExport?
        let error: String?

        init(provider: QuotaProvider, result: Result<QuotaExport, Error>) {
            self.provider = provider.rawValue
            switch result {
            case .success(let quota):
                self.quota = quota
                error = nil
            case .failure(let failure):
                quota = nil
                switch failure as? CodexQuotaClient.ClientError {
                case .processStopped: error = "Codex 服务已停止"
                case .server: error = "Codex 服务无法返回额度"
                default: error = failure.localizedDescription
                }
            }
        }
    }

    let sources: [Source]

    func exitStatus(failBelow: Int?, requireFresh: Bool) -> Int32 {
        if sources.contains(where: { $0.error != nil }) { return 1 }
        let statuses = sources.compactMap { $0.quota?.exitStatus(failBelow: failBelow, requireFresh: requireFresh) }
        return statuses.max() ?? 0
    }

    func render(as format: QuotaExport.Format) throws -> String {
        switch format {
        case .json:
            return try QuotaOutput.json(self)
        case .text:
            return try sources.map { source in
                if let quota = source.quota { return try quota.render(as: .text) }
                let title = QuotaProvider(rawValue: source.provider)?.title ?? source.provider
                return "\(title) · \(source.error ?? "")"
            }.joined(separator: "\n\n")
        case .csv:
            let columns = QuotaExport.csvColumns
            let rows = sources.flatMap { source in
                if let quota = source.quota { return quota.csvRows().map { $0 + [""] } }
                return [[source.provider] + Array(repeating: "", count: columns.count - 1) + [source.error ?? ""]]
            }
            return QuotaOutput.csv([columns + ["error"]] + rows)
        }
    }
}
