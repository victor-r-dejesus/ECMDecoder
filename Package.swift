// swift-tools-version:5.9
import PackageDescription

// The decoder as a library so it can be unit tested with `swift test`.
// The macOS app itself (App/) is built by scripts/build-app.sh.
let package = Package(
    name: "ECMDecoder",
    platforms: [.macOS(.v12)],
    targets: [
        .target(name: "ECMDecoderCore"),
        .testTarget(
            name: "ECMDecoderTests",
            dependencies: ["ECMDecoderCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
