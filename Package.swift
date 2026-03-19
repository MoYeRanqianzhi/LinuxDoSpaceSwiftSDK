// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LinuxDoSpace",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "LinuxDoSpace", targets: ["LinuxDoSpace"])
    ],
    targets: [
        .target(name: "LinuxDoSpace", path: "Sources/LinuxDoSpace")
    ]
)
