// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ViewTheWordCore",
    platforms: [.macOS("26.0")],
    products: [.library(name: "ViewTheWordCore", targets: ["ViewTheWordCore"])],
    targets: [
        .target(name: "ViewTheWordCore", path: "ViewTheWord", exclude: [
            "ViewTheWordApp.swift", "SparkleUpdateDriver.swift", "Resources", "Preview Content", "Info.plist",
            "ViewTheWord.entitlements", "ViewTheWordRelease.entitlements"
        ]),
        .testTarget(name: "ViewTheWordCoreTests", dependencies: ["ViewTheWordCore"], path: "Tests")
    ]
)
