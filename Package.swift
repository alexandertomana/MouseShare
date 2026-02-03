// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MouseShare",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MouseShare", targets: ["MouseShare"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "MouseShare",
            dependencies: [],
            path: "MouseShare/Sources/MouseShare",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
