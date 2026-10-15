// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SampleBrowser",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SampleGlide", targets: ["SampleBrowser"])],
    targets: [
        .target(
            name: "SampleBrowserAssets",
            path: "Assets",
            exclude: ["README.md", "AppIcon.icon.json"],
            resources: [.copy("AppIcon.png")]
        ),
        .executableTarget(name: "SampleBrowser", dependencies: ["SampleBrowserAssets"]),
        .testTarget(name: "SampleBrowserTests", dependencies: ["SampleBrowser"])
    ]
)
