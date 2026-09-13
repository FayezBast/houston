// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Houston",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Houston", targets: ["Houston"])],
    dependencies: [
        .package(url: "https://github.com/steipete/SweetCookieKit.git", exact: "0.5.2")
    ],
    targets: [
        .target(name: "HoustonCore", dependencies: [.product(name: "SweetCookieKit", package: "SweetCookieKit")]),
        .executableTarget(name: "Houston", dependencies: ["HoustonCore"], resources: [.copy("Resources/Logos")]),
        .testTarget(name: "HoustonCoreTests", dependencies: ["HoustonCore"]),
        .testTarget(name: "HoustonAppTests", dependencies: ["Houston"])
    ]
)
