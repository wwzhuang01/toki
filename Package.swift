// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Toki",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Toki", targets: ["Toki"])],
    targets: [
        .target(name: "TokiCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "Toki", dependencies: ["TokiCore"]),
        .testTarget(name: "TokiCoreTests", dependencies: ["TokiCore"])
    ]
)
