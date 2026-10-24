// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SortMyMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SortMyMac", targets: ["SortMyMac"])],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "SortMyMacCore", dependencies: ["CSQLite", "ZIPFoundation"]),
        .executableTarget(name: "SortMyMac", dependencies: ["SortMyMacCore"]),
        .testTarget(name: "SortMyMacCoreTests", dependencies: ["SortMyMacCore"]),
        .testTarget(name: "SortMyMacAppTests", dependencies: ["SortMyMac", "SortMyMacCore"])
    ]
)
