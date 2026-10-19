// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DiskChrona",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "DiskChrona", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "DiskChronaTests", dependencies: ["DiskChrona"]),
    ],
    swiftLanguageModes: [.v5]
)
