// swift-tools-version:5.9
import PackageDescription

// Standalone: reads orientation from the wabe daemon's socket, so it needs nothing from libwabe.
// Kept out of the main package so installing the service doesn't build a SceneKit app.
let package = Package(
    name: "tavoletta",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "tavoletta")]
)
