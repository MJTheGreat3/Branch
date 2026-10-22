// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Branch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Branch", targets: ["Branch"]),
        .executable(name: "BranchSnapshots", targets: ["BranchSnapshots"]),
        .library(name: "BranchCore", targets: ["BranchCore"]),
    ],
    targets: [
        .target(
            name: "BranchCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "BranchUI",
            dependencies: ["BranchCore"]
        ),
        .executableTarget(
            name: "Branch",
            dependencies: ["BranchCore", "BranchUI"]
        ),
        // Renders key windows to PNG offscreen, for reviewing UI without screen recording.
        .executableTarget(
            name: "BranchSnapshots",
            dependencies: ["BranchCore", "BranchUI"]
        ),
        .testTarget(
            name: "BranchCoreTests",
            dependencies: ["BranchCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
