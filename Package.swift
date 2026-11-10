// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Grid",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
    ],
    targets: [
        .executableTarget(
            name: "Grid",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")],
            path: "Sources/Grid"
        ),
        .testTarget(
            name: "GridTests",
            dependencies: ["Grid", .product(name: "ZIPFoundation", package: "ZIPFoundation")],
            path: "Tests/GridTests"
        )
    ]
)
