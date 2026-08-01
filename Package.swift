// swift-tools-version:5.9
import PackageDescription

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
