# SDK Process Connection Lease Validation

## Run Identity

- Captured: `2026-07-11T09:13:03Z`
- Base commit: `ea04c90d9869f6db1b68d2bb8f241a9fc7b1e09d`
- Xcode: `26.6 (17F113)`
- Swift: `6.3.3`, compiled in Swift 5 language mode
- CocoaPods: `1.16.2`
- OpenSpec: `1.2.0`
- Required compatibility targets: iOS 16 and macOS 13

## Focused Strict-Concurrency Gate

Command:

```text
HOME="$PWD/.build/home" XDG_CACHE_HOME="$PWD/.build/cache" CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" swift test --disable-sandbox --scratch-path "$PWD/.build/process-lease-tests" --filter ProcessConnectionLeaseTests -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Result: passed, 20 tests executed, 0 failures, 0 skipped.

The focused suite was rerun after all first-round review remediations. It covers permanent namespaces, selector resolution before monitor entry, one private monitor, sequential contention and owner preservation, explicit and deinitialization release, empty and stale release, ABA, start-gated concurrent first claims, retained-winner claim/release races, concurrent repeated and stale release, timeout cleanup before the serial gate unlocks, bootstrap and private-monitor enter/exit failures, runtime-unavailable precedence, Sendable declarations, closed fixed diagnostics, bounded token retention, no caller retention, and unrelated idle-instance shutdown.

## Structural and Multi-Image Gate

Command:

```text
./Scripts/verify-process-lease.sh
```

Result: passed.

- The structural audit and its negative mutation tests prove selector resolution before enter, enter-before-slot-access, explicit exit-before-outcome or cleanup construction, a unique private code-only error initializer across the struct and every extension, computed code-derived messages with no diagnostic storage path, exact-token release ordering, absence of validation accessors, and the fixed Apple runtime plus `ProcessInfo.processInfo` production path.
- Two dylibs were built separately with different Swift module names, each compiling its own copy of the production lease source.
- The watchdog-bounded loader proved identical permanent namespaces and private-monitor identity, cross-image contention, exact release, stale cross-image release safety, and reacquisition.
- Wrapper sources, loader code, generated dylibs, and wrapper symbols remained outside production sources and package products.

## Full Package Gate

Command:

```text
./Scripts/verify-package.sh
```

Result: passed after all first-round review remediations and after granting the unchanged command access to CoreSimulatorService.

Exact archive-candidate results:

- Core package fixture parity passed.
- Strict iOS 16 SwiftPM build passed in Swift 5 language mode.
- Strict macOS 13 Core and NearWire builds passed.
- Canonical SwiftPM and CocoaPods consumers compiled.
- `ProcessConnectionLeaseRegistry` was inaccessible to both external consumer modes.
- SwiftPM/CocoaPods supported API inventories matched and contained no process-lease type.
- SwiftPM SDK objects and the linked CocoaPods same-module iOS binary exported no multi-image harness wrapper symbol.
- Wire sealing, mandatory TLS, raw-connection construction, same-module transport, and identity-lifecycle boundaries passed unchanged.
- iOS Simulator tests: 246 passed, 0 failed, 0 skipped on iPhone 17 Pro / iOS 26.4 Simulator.
- macOS Core harness tests: 165 passed, 0 failed, 0 skipped.
- Production TLS 1.3 and ALPN tests executed rather than skipping.

The first sandboxed attempt could not connect to CoreSimulatorService. No command, test, or gate was weakened; the identical command then passed with simulator access.

## CocoaPods Gate

Command:

```text
./Scripts/verify-podspec.sh
```

Result: passed after all first-round review remediations and after granting the unchanged command access to CoreSimulatorService.

`NearWire (0.1.0)` and every Core, SDK, UI, and Performance subspec build path passed. The reserved bootstrap homepage `https://example.invalid/nearwire` produced the expected warning. AppIntents metadata notes are expected because NearWire has no AppIntents dependency. The initial sandboxed attempt failed only because the simulator service was unavailable; the command and validation policy were unchanged for the passing run.

## Repository Gates

Commands:

```text
DO_NOT_TRACK=1 openspec validate --all --strict --no-interactive
./Scripts/verify-boundaries.sh
./Scripts/verify-structure.sh
./Scripts/verify-english.sh
./Scripts/Tests/validation-tools.sh
./Scripts/verify-version.sh
swift format lint --recursive Package.swift Core SDK IntegrationTests/ProcessLeaseMultiImage Scripts/Fixtures
git diff --check
```

Results: passed.

- OpenSpec reported 21 passed and 0 failed items, including the active change and all 20 baseline specs.
- Swift module, Core SPI, secure-construction, package, pod, and exact distribution boundaries passed.
- Repository layout and validation-script executable checks passed.
- Evidence-capture, simulator-restoration, distribution-mutation, and validation-tool tests passed.
- English scanning, formatting, semantic version `0.1.0`, and whitespace checks passed.

## Supported API Inventory

The supported application API is unchanged. The registry, runtime adapter, low-level operation seam, runtime reference, errors, and handle are internal and non-SPI. No package target, product, third-party dependency, pod subspec, entitlement, privacy declaration, or public symbol was added.

## Residual Scope

This change adds no pairing parse or discovery run, TCP/TLS attempt, Keychain or persistence access, hello/admission handshake, event pump, flow scheduler, public connect or disconnect, reconnection, task, timer, App lifecycle observer, UI, Viewer publisher, or event transfer. The roadmap now assigns that work to session admission, active event pump, public connect, connection lifecycle, SDK UI, and Viewer changes.
