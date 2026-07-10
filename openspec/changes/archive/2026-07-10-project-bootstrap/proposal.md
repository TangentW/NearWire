## Why

NearWire currently exists only as an architecture document, so implementation cannot begin safely until the repository has a reproducible module layout, package manifests, quality gates, and a change delivery roadmap. This change establishes that foundation without implementing product behavior that belongs to later Core, SDK, or Viewer changes.

## What Changes

- Establish the monorepo layout for shared Core code, the iOS SDK, the macOS Viewer, the root Demo, integration tests, documentation, and scripts.
- Add a root Swift Package manifest that builds all shared and SDK modules in Swift 5 language mode with Xcode 16.
- Add a root CocoaPods podspec that maps the same source tree into Core, SDK, UI, and Performance subspecs.
- Add minimal compilable module entry points so package and test commands can run before feature implementation begins.
- Add repository-level validation scripts, a version source, a changelog, an English README, and an implementation roadmap.
- Define dependency isolation rules so Viewer-only packages never become transitive SDK dependencies.
- Define the evidence and review gates that every later OpenSpec change must satisfy.

## Capabilities

### New Capabilities

- `repository-structure`: Defines the authoritative monorepo directories, module ownership boundaries, and build entry points.
- `sdk-distribution`: Defines the root Swift Package and CocoaPods products, platform requirements, Swift language mode, and dependency isolation.
- `change-quality-gates`: Defines specification, test, documentation, multi-agent review, and completion evidence required for every implementation change.

### Modified Capabilities

None.

## Impact

- Adds repository metadata, manifests, documentation, scripts, source placeholders, and test placeholders.
- Establishes Xcode 16, iOS 16, macOS 13, Swift 5 language mode, and zero third-party runtime dependencies for Core and SDK.
- Does not yet implement event semantics, networking, discovery, storage, or Viewer UI behavior.
