// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "NearWireCoreHarness",
  platforms: [.macOS(.v13)],
  products: [],
  dependencies: [],
  targets: [
    .target(
      name: "NearWireCore",
      path: "Core/Sources/NearWireCore"
    ),
    .target(
      name: "NearWireTransport",
      dependencies: ["NearWireCore"],
      path: "Core/Sources/NearWireTransport"
    ),
    .target(
      name: "NearWireFlowControl",
      dependencies: ["NearWireCore"],
      path: "Core/Sources/NearWireFlowControl"
    ),
    .target(
      name: "NearWireTestSupport",
      dependencies: [
        "NearWireCore",
        "NearWireTransport",
        "NearWireFlowControl",
      ],
      path: "Core/TestSupport/NearWireTestSupport"
    ),
    .testTarget(
      name: "NearWireCoreTests",
      dependencies: ["NearWireCore"],
      path: "Core/Tests/NearWireCoreTests"
    ),
    .testTarget(
      name: "NearWireTransportTests",
      dependencies: ["NearWireTransport"],
      path: "Core/Tests/NearWireTransportTests"
    ),
    .testTarget(
      name: "NearWireFlowControlTests",
      dependencies: ["NearWireFlowControl"],
      path: "Core/Tests/NearWireFlowControlTests"
    ),
    .testTarget(
      name: "NearWireTestSupportTests",
      dependencies: ["NearWireTestSupport"],
      path: "Core/Tests/NearWireTestSupportTests"
    ),
  ],
  swiftLanguageVersions: [.v5]
)
