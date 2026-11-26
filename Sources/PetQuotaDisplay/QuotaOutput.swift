import Foundation

enum QuotaOutput {
    static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func csv(_ rows: [[String]]) -> String {
        let special = CharacterSet(charactersIn: ",\"\r\n")
        return rows.map { row in
            row.map { field in
                guard field.rangeOfCharacter(from: special) != nil else { return field }
                return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }
}
