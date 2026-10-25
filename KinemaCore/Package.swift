// swift-tools-version:5.9
import PackageDescription

// The platform-independent heart of Kinema: the Jellyfin client and its
// models, the device profile that tells the server what this iPhone can play,
// the stream resolver, the subtitle parsers, formatting and the settings
// model. The app target compiles these same sources directly; this package
// exists so they can be unit-tested with `swift test`, on a Mac or on Linux,
// without a simulator.
let package = Package(
    name: "KinemaCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "KinemaCore", targets: ["KinemaCore"]),
    ],
    targets: [
        .target(name: "KinemaCore"),
        .testTarget(
            name: "KinemaCoreTests",
            dependencies: ["KinemaCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
