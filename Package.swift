// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NotchPulse",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchPulse",
            path: "Sources/NotchPulse",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
