// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vaqlo",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Vaqlo",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: ".",
            exclude: ["dist", "vendor", "scripts", "Resources", "VaqloControl.xcodeproj",
                      "project.yml", "ControlExtension/VaqloControl.swift",
                      "ControlExtension/Info.plist", "ControlExtension/VaqloControl.entitlements"],
            sources: ["Sources/Vaqlo", "ControlExtension/VaqloShared.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
