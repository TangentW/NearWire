// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "NearWire",
  platforms: [
    .iOS(.v16),
    .macOS(.v13),
  ],
  products: [
    .library(
      name: "NearWire",
      targets: ["NearWire"]
    ),
    .library(
      name: "NearWireUI",
      targets: ["NearWireUI"]
    ),
    .library(
      name: "NearWirePerformance",
      targets: ["NearWirePerformance"]
    ),
    .library(
      name: "NearWireCore",
      targets: [
        "NearWireCore",
        "NearWireTransport",
        "NearWireFlowControl",
      ]
    ),
  ],
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
      name: "NearWire",
      dependencies: [
        "NearWireCore",
        "NearWireTransport",
        "NearWireFlowControl",
      ],
      path: "SDK/Sources/NearWire",
      linkerSettings: [
        .linkedFramework("Security")
      ]
    ),
    .target(
      name: "NearWireUI",
      dependencies: ["NearWire"],
      path: "SDK/Sources/NearWireUI"
    ),
    .target(
      name: "NearWirePerformance",
      dependencies: [
        "NearWire",
        "NearWireCore",
      ],
      path: "SDK/Sources/NearWirePerformance"
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
    .testTarget(
      name: "NearWireTests",
      dependencies: [
        "NearWire",
        "NearWireTransport",
      ],
      path: "SDK/Tests/NearWireTests"
    ),
    .testTarget(
      name: "NearWireUITests",
      dependencies: ["NearWireUI"],
      path: "SDK/Tests/NearWireUITests"
    ),
    .testTarget(
      name: "NearWirePerformanceTests",
      dependencies: ["NearWirePerformance"],
      path: "SDK/Tests/NearWirePerformanceTests"
    ),
  ],
  swiftLanguageVersions: [.v5]
)
