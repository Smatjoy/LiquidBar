// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "LiquidBar",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "LiquidBar", targets: ["LiquidBar"]),
    // Loaded into /usr/bin/perl at runtime, never linked into the app.
    .library(name: "NowPlayingBridge", type: .dynamic, targets: ["NowPlayingBridge"]),
  ],
  targets: [
    .executableTarget(
      name: "LiquidBar",
      swiftSettings: [
        .defaultIsolation(MainActor.self),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("InferIsolatedConformances"),
      ]
    ),
    .target(
      name: "NowPlayingBridge",
      cSettings: [.unsafeFlags(["-fobjc-arc"])],
      linkerSettings: [.linkedFramework("Foundation")]
    ),
  ]
)
