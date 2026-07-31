// swift-tools-version:5.9
import PackageDescription

// The Swift tools: the control CLI and offline replay. Everything else is the Makefile's.
//
// wabed is deliberately absent. It builds from Sources/wabed with clang via `make`, and declaring
// it here as well produced a second daemon binary from the same source under different flags —
// with `wabe install` shipping whichever one happened to sit beside it. One daemon, one compiler.
// libwabe stays because wabe-replay links it.
//
// The SceneKit demo is a separate package in examples/tavoletta, so building or installing wabe
// doesn't drag in an app you didn't ask for.
let package = Package(
    name: "wabe",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "libwabe", targets: ["libwabe"]),
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
        .executableTarget(name: "wabe", dependencies: []),
        .executableTarget(name: "wabe-replay", dependencies: ["libwabe"]),
    ],
    cxxLanguageStandard: .cxx14
)
