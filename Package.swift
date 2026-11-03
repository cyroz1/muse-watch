// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MuseWatch",
    platforms: [
        .watchOS(.v10),
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "MuseKit", targets: ["MuseKit"])
    ],
    targets: [
        .target(name: "MuseKit"),
        .executableTarget(name: "MuseKitChecks", dependencies: ["MuseKit"], path: "Checks", resources: [.copy("Fixtures")])
    ]
)
