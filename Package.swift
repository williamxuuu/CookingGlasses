// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CookingGlasses",
    platforms: [.iOS("17.2"), .macOS(.v13)],
    products: [.library(name: "CookingCore", targets: ["CookingCore"])],
    targets: [
        .target(name: "CookingCore"),
        .testTarget(name: "CookingCoreTests", dependencies: ["CookingCore"])
    ],
    swiftLanguageVersions: [.v5]
)
