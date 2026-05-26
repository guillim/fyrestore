// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Fyrestore",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Fyrestore", targets: ["Fyrestore"])
    ],
    targets: [
        .executableTarget(
            name: "Fyrestore",
            path: "Sources/Fyrestore"
        )
    ]
)
