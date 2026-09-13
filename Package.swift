// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Houston",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Houston", targets: ["Houston"])],
    targets: [
        .target(name: "HoustonCore"),
        .executableTarget(name: "Houston", dependencies: ["HoustonCore"], resources: [.copy("Resources/Logos")]),
        .testTarget(name: "HoustonCoreTests", dependencies: ["HoustonCore"]),
        .testTarget(name: "HoustonAppTests", dependencies: ["Houston"])
    ]
)
