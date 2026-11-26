import Foundation

enum QuotaCLI {
    static func find(
        _ executable: String,
        override variable: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let files = FileManager.default
        if let path = environment[variable] {
            return executableURL(at: path)
        }
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + [
            files.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        return directories.lazy.compactMap { directory in
            executableURL(at: URL(fileURLWithPath: directory).appendingPathComponent(executable).path)
        }.first
    }

    static func executableURL(at path: String) -> URL? {
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"),
              files.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
              files.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
