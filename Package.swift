// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SortMyMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SortMyMac", targets: ["SortMyMac"])],
    targets: [
        .target(name: "SortMyMacCore"),
        .executableTarget(name: "SortMyMac", dependencies: ["SortMyMacCore"]),
        .testTarget(name: "SortMyMacCoreTests", dependencies: ["SortMyMacCore"])
    ]
)
