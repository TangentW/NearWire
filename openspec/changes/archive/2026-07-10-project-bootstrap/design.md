## Context

The repository contains a complete product architecture document but no manifests, source directories, tests, or build entry points. The project must support an iOS 16 SDK through Swift Package Manager and CocoaPods, a native macOS 13 Viewer, shared Core modules, a root Demo, and a strict OpenSpec delivery workflow. Xcode 16 is the minimum toolchain, while distributed source must remain in Swift 5 language mode.

## Goals / Non-Goals

**Goals:**

- Create an authoritative monorepo structure with explicit module ownership.
- Make the shared and SDK module graph compile and test through Swift Package Manager.
- Describe the same SDK source tree through one root CocoaPods podspec.
- Establish English documentation, versioning, validation scripts, and a sequential OpenSpec change roadmap.
- Make review evidence and zero-unresolved-finding gates part of the repository contract.

**Non-Goals:**

- Implement event models, queues, networking, Bonjour, TLS sessions, persistence, or product UI.
- Select Viewer-only third-party libraries.
- Create production signing, distribution, or update infrastructure.
- Claim compatibility with legacy Swift 5.0 compilers; compatibility means Swift 5 language mode on Xcode 16.

## Decisions

### 1. Use one repository with three ownership roots

`Core`, `SDK`, and `Viewer` are the only production ownership roots. `Demo`, `IntegrationTests`, `Documentation`, and `Scripts` are repository-level support roots. This avoids a generic `Shared` directory and makes platform-specific ownership visible from the path.

Alternative considered: separate SDK and Viewer repositories. Rejected because protocol fixtures, Core sources, release versions, and end-to-end tests would drift across repositories.

### 2. Keep one root Swift Package manifest

The root `Package.swift` uses explicit target paths. Initial targets are `NearWireCore`, `NearWireTransport`, `NearWireFlowControl`, `NearWire`, `NearWireUI`, `NearWirePerformance`, and `NearWireTestSupport`. Core products are visible to the local Viewer build but are documented as internal and carry no external API compatibility promise.

Supported public SDK signatures must not expose Core-declared types. Consumer-facing event and configuration models are declared in supported SDK modules and convert to internal Core wire models at the module boundary. SwiftPM and CocoaPods consumer compile fixtures enforce equivalent public usage despite their different module layouts.

The manifest uses `swift-tools-version: 5.9`, iOS 16, macOS 13, and Swift 5 language mode. Tools version controls manifest features; it does not change the source language compatibility setting.

Alternative considered: one package manifest per directory. Rejected because it duplicates dependency graphs and makes release validation harder.

### 3. Keep one root podspec over the same source tree

`NearWire.podspec` defines Core, SDK, UI, and Performance subspecs, with SDK as the default and Core as an internal dependency. CocoaPods compiles selected subspec sources into the NearWire pod module, while SwiftPM builds separate targets. Cross-target Swift imports therefore use `#if SWIFT_PACKAGE` where required. Import validation remains enabled, and later public API changes add equivalent compile fixtures for SwiftPM and CocoaPods consumers.

Alternative considered: multiple podspecs for independent Core modules. Rejected because the approved project contract requires one root podspec and the extra public pods would expose internal modules.

### 4. Keep Core and SDK free of third-party runtime dependencies

The root Package manifest contains no external package dependencies. Viewer-only dependencies are added to `Viewer/NearWireViewer.xcodeproj` and pinned in the Viewer workspace's `Package.resolved`. This prevents SDK consumers from resolving unrelated Viewer packages.

### 5. Use minimal internal module markers during bootstrap

Each target receives a minimal internal source file and a smoke test. Bootstrap symbols are not public API and may be replaced by later feature changes. This makes package validation possible without prematurely defining event or networking behavior.

### 6. Defer production Viewer and Demo projects to their feature changes

Bootstrap creates the authoritative directories and an empty root workspace. The manually maintained Viewer and Demo Xcode projects are created when their first implementation changes begin, so bootstrap does not introduce fragile placeholder project files.

### 7. Use one release version and a separate protocol version

The root `VERSION`, podspec version, Viewer marketing version, and Git release tag remain aligned. Protocol compatibility is represented separately in Core and may remain stable across product releases.

### 8. Make OpenSpec and multi-agent review a hard delivery gate

Every feature change must have proposal, design when applicable, capability specs, and tasks before apply work. After implementation and tests, at least three independent review perspectives cover architecture/API, correctness/testing, and security/performance/documentation. Findings are fixed and another review round is run until no unresolved findings remain. Only then may the change be archived and the next change enter apply.

Review reports live under the active change directory so evidence remains tied to the specification and task list.

## Risks / Trade-offs

- [Swift 5 mode can hide Swift 6 isolation errors] -> Run strict-concurrency diagnostics in validation while preserving Swift 5 language mode for consumers.
- [One pod module differs from SwiftPM's multi-module build] -> Keep conditional imports small and test every subspec in dedicated integration fixtures.
- [Manual Xcode projects can accumulate merge conflicts] -> Keep them out of bootstrap, use stable groups, and review project file diffs in Viewer and Demo changes.
- [Internal Core products remain technically importable] -> Exclude them from integration documentation and explicitly deny external compatibility guarantees.
- [Placeholder modules could become accidental API] -> Keep all marker declarations internal and replace them before release.
- [Viewer-only dependencies could leak into SDK resolution] -> Keep the root package dependency list empty and add an automated dependency graph check.

## Migration Plan

1. Create and validate the OpenSpec artifacts for `project-bootstrap`.
2. Add repository metadata, source roots, module markers, tests, manifests, documentation, and scripts.
3. Run package, podspec, structure, and English-language validation.
4. Run multi-agent review rounds, fix every finding, and repeat validation.
5. Archive the completed change so its capability specs become the baseline for later changes.

Rollback is file-based because there is no deployed state or user data. Reverting the bootstrap change removes the generated project foundation without migration work.

## Open Questions

None. Product-level structure decisions are already recorded in the architecture document.
