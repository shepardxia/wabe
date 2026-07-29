// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wabe",
    platforms: [.macOS(.v13)],
    products: [
        // All computation lives in the C library: sensor I/O, sample merge, VQF orientation
        // filter (vendored C++, invisible behind the C API), pose extraction, daemon service.
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
        // Daemon: thin C shell (args + accel-dead re-exec).
        .executableTarget(name: "wabed", dependencies: ["libwabe"]),
        // Swift stays as connective tissue: socket consumers and offline tooling.
        .executableTarget(name: "wabe", dependencies: []),
        .executableTarget(name: "wabe-demo", dependencies: []),
        .executableTarget(name: "wabe-replay", dependencies: ["libwabe"]),
    ],
    cxxLanguageStandard: .cxx14
)
