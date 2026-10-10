// swift-tools-version:5.9
import PackageDescription

var targets: [Target] = [
    .target(name: "ECMCore"),
    // Fixtures are read from disk via #filePath, so keep them out of the build
    // (otherwise SwiftPM warns about unhandled .ecm/.bin files).
    .testTarget(name: "ECMCoreTests", dependencies: ["ECMCore"], exclude: ["Fixtures"]),
]
var products: [Product] = [
    .library(name: "ECMCore", targets: ["ECMCore"]),
]

#if os(macOS)
// The SwiftUI front end only builds on macOS; the decoder core and tests build anywhere.
targets.append(.executableTarget(name: "ECMDecoderApp", dependencies: ["ECMCore"]))
products.append(.executable(name: "ECMDecoderApp", targets: ["ECMDecoderApp"]))
#endif

let package = Package(
    name: "ECMDecoder",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
