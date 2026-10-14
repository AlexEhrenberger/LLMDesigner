// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LLMDesigner",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "Vendor/SwiftMath")
    ],
    targets: [
        .executableTarget(
            name: "LLMDesigner",
            dependencies: [.product(name: "SwiftMath", package: "SwiftMath")],
            path: "Sources/LLMDesigner",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
