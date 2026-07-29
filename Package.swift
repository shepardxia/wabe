// swift-tools-version:5.9
import PackageDescription

// The service: a C library, the daemon, the control CLI, and offline replay.
// The SceneKit demo is a separate package in examples/magic-window, so building or installing
// wabe doesn't drag in an app you didn't ask for.
let package = Package(
    name: "wabe",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "libwabe", targets: ["libwabe"]),
        .executable(name: "wabed", targets: ["wabed"]),
        .executable(name: "wabe", targets: ["wabe"]),
    ],
    targets: [
        .target(
            name: "libwabe",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("c++"),
            ]
        ),
        .executableTarget(name: "wabed", dependencies: ["libwabe"]),
        .executableTarget(name: "wabe", dependencies: []),
        .executableTarget(name: "wabe-replay", dependencies: ["libwabe"]),
    ],
    cxxLanguageStandard: .cxx14
)
