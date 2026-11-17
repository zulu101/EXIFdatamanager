// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ExifDataManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ExifDataManager", targets: ["ExifDataManager"]),
    ],
    targets: [
        // Reine Metadaten-Logik (ImageIO), ohne UI – dadurch gut testbar.
        .target(name: "ExifCore"),
        // Die SwiftUI-App.
        .executableTarget(name: "ExifDataManager", dependencies: ["ExifCore"]),
        .testTarget(name: "ExifCoreTests", dependencies: ["ExifCore"]),
    ]
)
