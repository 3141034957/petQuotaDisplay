import QuotaCore

struct CodexModelCatalog {
    struct Model: Encodable {
        let id: String
        let name: String
        let isPrimary: Bool
        let periods: [String]

        init(id: String, name: String, isPrimary: Bool, snapshot: QuotaSnapshot) {
            self.id = id
            self.name = name
            self.isPrimary = isPrimary
            periods = QuotaPeriod.allCases.filter { snapshot[$0] != nil }.map(\.rawValue)
        }
    }

    let models: [Model]

    init(_ report: CodexQuotaReport) {
        models = [Model(id: report.primaryID, name: "主要额度", isPrimary: true, snapshot: report.primary)]
            + report.additional.map { Model(id: $0.id, name: $0.name, isPrimary: false, snapshot: $0.snapshot) }
    }

    func render(as format: QuotaExport.Format) throws -> String {
        switch format {
        case .json:
            return try QuotaOutput.json(models)
        case .text:
            return models.map { "\($0.id) · \($0.name) · \($0.periods.joined(separator: ", "))" }.joined(separator: "\n")
        case .csv:
            let columns = ["id", "name", "isPrimary", "periods"]
            return QuotaOutput.csv([columns] + models.map { [$0.id, $0.name, String($0.isPrimary), $0.periods.joined(separator: " ")] })
        }
    }
}
