// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PhotosShare",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PhotosShare",
            path: "Sources/PhotosShare"
        ),
    ]
)
