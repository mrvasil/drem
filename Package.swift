// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Drem",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Drem", targets: ["Drem"]),
        .executable(name: "dremctl", targets: ["DremCLI"]),
        .executable(name: "drem-selftest", targets: ["DremSelfTest"]),
        .executable(name: "drem-hook", targets: ["DremHook"])
    ],
    targets: [
        .target(name: "DremCore"),
        .target(name: "DremBrand"),
        .testTarget(name: "DremTests", dependencies: ["Drem", "DremCore", "DremBrand"]),
        .executableTarget(
            name: "Drem",
            dependencies: ["DremCore", "DremBrand"]
        ),
        .executableTarget(
            name: "DremCLI",
            dependencies: ["DremCore"]
        ),
        .executableTarget(
            name: "DremSelfTest",
            dependencies: ["DremCore"]
        ),
        .executableTarget(
            name: "DremHook",
            dependencies: ["DremCore"]
        )
    ]
)
