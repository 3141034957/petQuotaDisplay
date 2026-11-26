import QuotaCore

struct QuotaHistoryStatistics: Encodable {
    struct Period: Encodable {
        let id: String
        let readingCount: Int
        let minimumRemainingPercent: Int
        let maximumRemainingPercent: Int
        let latestRemainingPercent: Int
    }

    struct Source: Encodable {
        let provider: String
        let modelID: String?
        let readingCount: Int
        let periods: [Period]

        init(_ export: QuotaHistoryExport) {
            provider = export.provider
            modelID = export.modelID
            readingCount = export.readings.count
            periods = QuotaPeriod.allCases.compactMap { period in
                let values = export.readings.compactMap { reading in
                    reading.periods.first { $0.id == period.rawValue }?.remainingPercent
                }
                guard let latest = values.last, let minimum = values.min(), let maximum = values.max() else { return nil }
                return Period(id: period.rawValue, readingCount: values.count, minimumRemainingPercent: minimum,
                              maximumRemainingPercent: maximum, latestRemainingPercent: latest)
            }
        }
    }

    let schemaVersion = 1
    let sources: [Source]

    init(_ exports: [QuotaHistoryExport]) {
        sources = exports.map(Source.init)
    }

    func render(as format: QuotaExport.Format) throws -> String {
        switch format {
        case .json:
            return try QuotaOutput.json(self)
        case .text:
            return sources.map { source in
                let provider = QuotaProvider(rawValue: source.provider)?.title ?? source.provider
                let heading = [provider, source.modelID, "\(source.readingCount) 次采集"].compactMap { $0 }
                    .joined(separator: " · ")
                let lines = source.periods.map { period in
                    let title = QuotaPeriod(rawValue: period.id)?.title ?? period.id
                    return "\(title) · \(period.readingCount) 条 · \(period.minimumRemainingPercent)–\(period.maximumRemainingPercent)% · 最近 \(period.latestRemainingPercent)%"
                }
                return ([heading] + lines).joined(separator: "\n")
            }.joined(separator: "\n\n")
        case .csv:
            let columns = ["provider", "modelID", "period", "readingCount", "minimumRemainingPercent",
                           "maximumRemainingPercent", "latestRemainingPercent"]
            let rows = sources.flatMap { source in
                source.periods.map { period in
                    [source.provider, source.modelID ?? "", period.id, String(period.readingCount),
                     String(period.minimumRemainingPercent), String(period.maximumRemainingPercent),
                     String(period.latestRemainingPercent)]
                }
            }
            return QuotaOutput.csv([columns] + rows)
        }
    }
}
