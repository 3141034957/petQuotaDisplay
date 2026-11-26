import Foundation

enum QuotaBuildInformation {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var revision: String? {
        Bundle.main.object(forInfoDictionaryKey: "PetQuotaDisplayRevision") as? String
    }

    static var summary: String {
        let release = "PetQuotaDisplay \(version)"
        return revision.map { "\(release) (\($0))" } ?? release
    }
}
