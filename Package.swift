// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "PetQuotaDisplay",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PetQuotaDisplay", targets: ["PetQuotaDisplay"]),
        .library(name: "QuotaCore", targets: ["QuotaCore"]),
    ],
    targets: [
        .target(name: "QuotaCore"),
        .executableTarget(name: "PetQuotaDisplay", dependencies: ["QuotaCore"]),
        .testTarget(name: "QuotaCoreTests", dependencies: ["QuotaCore"]),
    ]
)
