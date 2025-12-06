// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodeCartographer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "codecart", targets: ["CodeCartographer"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax.git", from: "510.0.0")
    ],
    targets: [
        .executableTarget(
            name: "CodeCartographer",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax")
            ]
        )
    ]
)
