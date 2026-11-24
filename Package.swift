// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nachsatz",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "NachsatzCore"),
        .executableTarget(name: "Nachsatz", dependencies: ["NachsatzCore"]),
        .executableTarget(name: "Check", dependencies: ["NachsatzCore"]),
        .executableTarget(name: "Compare", dependencies: ["NachsatzCore"]),
    ],
    swiftLanguageModes: [.v5]
)
