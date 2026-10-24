// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BetterNotch",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "BetterNotch", targets: ["BetterNotch"])],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "BetterNotchCore", dependencies: ["CSQLite", "ZIPFoundation"]),
        .executableTarget(name: "BetterNotch", dependencies: ["BetterNotchCore"]),
        .executableTarget(name: "BetterNotchCodexBridge", dependencies: ["BetterNotchCore"]),
        .testTarget(name: "BetterNotchCoreTests", dependencies: ["BetterNotchCore"]),
        .testTarget(name: "BetterNotchAppTests", dependencies: ["BetterNotch", "BetterNotchCore"])
    ]
)
