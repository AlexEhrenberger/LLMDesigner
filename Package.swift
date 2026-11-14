// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LLMDesigner",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "llmd", targets: ["llmd"]),
    ],
    dependencies: [
        .package(path: "Vendor/SwiftMath")
    ],
    targets: [
        .target(
            name: "LLMDProtocol",
            path: "Sources/LLMDProtocol",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "LibraryMerge",
            path: "Sources/LibraryMerge",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "LLMDesigner",
            dependencies: [.product(name: "SwiftMath", package: "SwiftMath"), "LLMDProtocol", "LibraryMerge"],
            path: "Sources/LLMDesigner",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "llmd",
            dependencies: ["LLMDProtocol", "LibraryMerge"],
            path: "Sources/llmd",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LLMDesignerTests",
            dependencies: ["LLMDesigner", "LLMDProtocol", "LibraryMerge"],
            path: "Tests/LLMDesignerTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "llmdTests",
            dependencies: ["llmd", "LLMDProtocol"],
            path: "Tests/llmdTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
