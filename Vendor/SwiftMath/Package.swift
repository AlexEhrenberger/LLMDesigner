// swift-tools-version: 5.7
// Vendored copy of SwiftMath 1.7.3 (https://github.com/mgriebling/SwiftMath, MIT).
// Local changes: see README.md in this folder.
import PackageDescription

let package = Package(
    name: "SwiftMath",
    platforms: [.macOS("12.0")],
    products: [
        .library(name: "SwiftMath", targets: ["SwiftMath"]),
    ],
    targets: [
        .target(
            name: "SwiftMath",
            resources: [.copy("mathFonts.bundle")]
        ),
    ]
)
