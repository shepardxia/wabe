// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wabe",
    platforms: [.macOS(.v13)],
    targets: [
        // C core: IOKit HID reader for the SPU sensors. Runs its own CFRunLoop thread and
        // exposes drain-style ring buffers; everything above it is Swift.
        .target(
            name: "CWabeSensor",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(name: "WabeCore", dependencies: ["CWabeSensor"]),
        .executableTarget(name: "wabed", dependencies: ["WabeCore"]),
        .executableTarget(name: "wabe-cli", dependencies: []),
        .executableTarget(name: "wabe-demo", dependencies: []),
    ]
)
