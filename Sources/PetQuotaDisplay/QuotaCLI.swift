import Foundation

enum QuotaCLI {
    static func find(_ executable: String, override variable: String) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let files = FileManager.default
        if let path = environment[variable] {
            guard !path.isEmpty, files.isExecutableFile(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + [
            files.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent(executable) }
            .first { files.isExecutableFile(atPath: $0.path) }
    }
}
