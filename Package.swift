// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "alt-tab",
    platforms: [.macOS(.v12)],
    dependencies: [
        // Updater engine. The framework is embedded into AltTab.app by
        // make-app.sh / the release workflow, and staged next to the binary
        // for unpackaged runs by scripts/stage-sparkle.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")
    ],
    targets: [
        .executableTarget(
            name: "AltTabCore",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/AltTabCore",
            linkerSettings: [
                .unsafeFlags(["-weak_framework", "MultitouchSupport", "-F", "/System/Library/PrivateFrameworks"]),
                // Resolves Sparkle.framework in both layouts: Contents/Frameworks
                // for the bundle and <products-dir>/Frameworks for staged dev runs.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
