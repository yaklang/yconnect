// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "yconnect-darwin",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "YConnect", targets: ["YConnect"]),
    ],
    targets: [
        .executableTarget(
            name: "YConnect",
            path: "Sources/YConnect",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("WebKit"),
            ]
        ),
        .testTarget(
            name: "YConnectTests",
            dependencies: ["YConnect"],
            path: "Tests/YConnectTests"
        ),
    ]
)
