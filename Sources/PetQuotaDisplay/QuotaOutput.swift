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
            row.map { original in
                let field = spreadsheetText(original)
                guard field.rangeOfCharacter(from: special) != nil else { return field }
                return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }

    private static func spreadsheetText(_ value: String) -> String {
        let firstVisible = value.first { !$0.isWhitespace }
        guard let firstVisible, "=+-@".contains(firstVisible) else { return value }
        return "'\(value)"
    }
}
