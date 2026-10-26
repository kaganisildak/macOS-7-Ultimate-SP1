// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "win7mac",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "Win7Theme"),
        .target(
            name: "Win7ChromeCore",
            dependencies: ["Win7Theme"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreText"),
            ]
        ),
        .target(name: "Win7Core"),
        .executableTarget(
            name: "Win7Shell",
            dependencies: ["Win7Core", "Win7Theme", "Win7ChromeCore"],
            linkerSettings: [
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Carbon"),
                .linkedFramework("Network"),
            ]
        ),
        .executableTarget(
            name: "Win7AssetTool",
            dependencies: ["Win7Core"],
            linkerSettings: [
                .linkedFramework("ImageIO"),
            ]
        ),
        .executableTarget(
            name: "Win7RenderTool",
            dependencies: ["Win7Theme", "Win7ChromeCore"]
        ),
        .testTarget(name: "Win7ThemeTests", dependencies: ["Win7Theme"]),
        .testTarget(name: "Win7ChromeCoreTests", dependencies: ["Win7ChromeCore"]),
        // Fixtures/ are read by path (#filePath), as scripts/fixtures are.
        .testTarget(name: "Win7CoreTests", dependencies: ["Win7Core"], exclude: ["Fixtures"]),
        .testTarget(name: "Win7RenderToolTests", dependencies: ["Win7RenderTool"]),
        // micro-benchmarks, in a process of their own (see Tests/Win7PerfTests).
        .testTarget(name: "Win7PerfTests", dependencies: ["Win7Core", "Win7Theme", "Win7ChromeCore"]),
    ]
)
