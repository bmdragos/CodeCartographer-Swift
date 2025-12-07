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
            ],
            swiftSettings: [
                // Workaround for Swift 6 / Xcode 16 CopyPropagation optimizer bug
                // The optimizer incorrectly removes "live" objects causing crashes
                .unsafeFlags([
                    "-Xfrontend", "-enable-copy-propagation=false"
                ], .when(configuration: .release))
            ]
        )
    ]
)
