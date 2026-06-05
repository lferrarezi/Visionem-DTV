// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SianoTVPlayer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SianoTVPlayer", targets: ["SianoTVPlayer"])
    ],
    targets: [
        .executableTarget(
            name: "SianoTVPlayer",
            path: "Sources"
        )
    ]
)
