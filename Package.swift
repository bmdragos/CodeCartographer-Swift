// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodeCartographer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "codecart", targets: ["CodeCartographer"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax.git", from: "600.0.0")
    ],
    targets: [
        .executableTarget(
            name: "CodeCartographer",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax")
            ],
            swiftSettings: [
                // Workaround for Swift 6 / Xcode 16 CopyPropagation optimizer bug
                .unsafeFlags([
                    "-Xfrontend", "-enable-copy-propagation=false"
                ], .when(configuration: .release))
            ]
        ),
        .testTarget(
            name: "CodeCartographerTests",
            dependencies: ["CodeCartographer"]
        )
    ]
)
