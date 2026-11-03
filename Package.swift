// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "alt-tab",
    targets: [
        .executableTarget(
            name: "AltTabCore",
            path: "Sources/AltTabCore",
            linkerSettings: [.unsafeFlags(["-weak_framework", "MultitouchSupport", "-F", "/System/Library/PrivateFrameworks"])]
        )
    ]
)
