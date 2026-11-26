import Foundation

struct QuotaBuildInformation: Encodable {
    static let current = QuotaBuildInformation(bundle: .main)

    let version: String
    let buildNumber: String?
    let revision: String?

    private init(bundle: Bundle) {
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        revision = bundle.object(forInfoDictionaryKey: "PetQuotaDisplayRevision") as? String
    }

    var summary: String {
        let release = "PetQuotaDisplay \(version)"
        return revision.map { "\(release) (\($0))" } ?? release
    }

    var aboutDetails: String? {
        let details = [buildNumber.map { "构建号 \($0)" }, revision].compactMap { $0 }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }
}
