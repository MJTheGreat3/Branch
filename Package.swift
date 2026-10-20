// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Branch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Branch", targets: ["Branch"]),
        .library(name: "BranchCore", targets: ["BranchCore"]),
    ],
    targets: [
        .target(
            name: "BranchCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Branch",
            dependencies: ["BranchCore"]
        ),
        .testTarget(
            name: "BranchCoreTests",
            dependencies: ["BranchCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
