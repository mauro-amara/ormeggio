// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ormeggio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Ormeggio",
            path: "Sources/Ormeggio"
        ),
        // Controlli automatici contro le regressioni: girano a ogni compilazione, prima di pubblicare.
        .testTarget(
            name: "OrmeggioTests",
            dependencies: ["Ormeggio"],
            path: "Tests/OrmeggioTests"
        )
    ]
)
