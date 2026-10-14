// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FreeMount",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "FreeMount",
            targets: ["FreeMount"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "FreeMount",
            dependencies: [],
            path: "App",
            exclude: [
                "CONTEXT.md",
                // An `.appex` is embedded and signed by the Xcode distribution
                // target. SwiftPM continues to build the host app and the
                // shared File Provider domain code for fast unit tests.
                "FileProviderExtension",
                "Resources/FreeMount.entitlements",
                "Resources/Info.plist"
            ]
        ),
        .testTarget(
            name: "FreeMountTests",
            dependencies: ["FreeMount"],
            path: "Tests",
            exclude: ["CONTEXT.md"]
        )
    ]
)
