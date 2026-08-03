// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wabe",
    platforms: [.macOS(.v13)],
    // `wabe` itself is not here on purpose: it is C, the Makefile is the only place it is built,
    // and installing the service must not need a Swift toolchain. Swift is for the replay tool.
    products: [
        .library(name: "libwabe", targets: ["libwabe"]),
    ],
    targets: [
        .target(
            name: "libwabe",
            exclude: ["../wabe"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("c++"),
            ]
        ),
        .executableTarget(name: "wabe-replay", dependencies: ["libwabe"]),
    ],
    cxxLanguageStandard: .cxx14
)
