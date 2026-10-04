// swift-tools-version:6.0
import PackageDescription

var products: [Product] = [
    .library(name: "DiskUsageCore", targets: ["DiskUsageCore"]),
]

var targets: [Target] = [
    .target(name: "DiskUsageCore"),
    .testTarget(name: "DiskUsageCoreTests", dependencies: ["DiskUsageCore"]),
]

#if os(macOS)
products.append(.executable(name: "DiskUsageApp", targets: ["DiskUsageApp"]))
targets.append(.executableTarget(name: "DiskUsageApp", dependencies: ["DiskUsageCore"]))
#endif

let package = Package(
    name: "MacDiskUsage",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
