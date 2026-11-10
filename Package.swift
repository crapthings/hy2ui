// swift-tools-version: 6.0
import PackageDescription

// Describes the independently testable model and connection-lifecycle modules.
let package = Package(
    name: "Hy2UI",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Hy2Models", targets: ["Hy2Models"]),
        .library(name: "Hy2Connection", targets: ["Hy2Connection"])
    ],
    targets: [
        .target(name: "Hy2Models", path: "Shared", resources: [.process("Resources")]),
        .target(name: "Hy2Connection", dependencies: ["Hy2Models"], path: "Connection"),
        .testTarget(name: "Hy2ModelsTests", dependencies: ["Hy2Models"], path: "Tests/Hy2ModelsTests"),
        .testTarget(name: "Hy2ConnectionTests", dependencies: ["Hy2Connection", "Hy2Models"], path: "Tests/Hy2ConnectionTests")
    ]
)
