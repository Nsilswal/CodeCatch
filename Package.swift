// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CodeCatch",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CodeCatchCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "CodeCatch",
            dependencies: ["CodeCatchCore"]
        ),
        .testTarget(
            name: "CodeCatchCoreTests",
            dependencies: ["CodeCatchCore"]
        ),
    ]
)
