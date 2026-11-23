// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ormeggio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Ormeggio",
            path: "Sources/Ormeggio"
        )
    ]
)
