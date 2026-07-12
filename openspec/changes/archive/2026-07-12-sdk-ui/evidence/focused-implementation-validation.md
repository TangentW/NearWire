# Focused Implementation Validation

Date: 2026-07-12, Asia/Shanghai

## Strict NearWireUI Tests

Command:

```sh
env HOME="$PWD/.build/home" \
  XDG_CACHE_HOME="$PWD/.build/cache" \
  CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
  swift test --cache-path "$PWD/.build/cache" \
  --config-path "$PWD/.build/config" \
  --security-path "$PWD/.build/security" \
  --manifest-cache local --disable-dependency-cache \
  --disable-build-manifest-caching --disable-sandbox \
  --filter NearWireUITests \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
```

Exact final result:

```text
Test Suite 'Selected tests' passed.
Executed 43 tests, with 0 failures (0 unexpected).
```

The suite covers the closed state and action presentations; UTF-8 scalar-prefix boundaries; safe unknown errors; status/action error ordering; exact input forwarding; simultaneous panels; exact subscriber removal; construction and release; no active-session disconnect on disappearance; Connect A cancellation before Connect B; shared operation deduplication; cross-panel cancellation in both completion orders; reverse phase-delivery convergence; mounted public-view instance replacement; reentrant cancellation; and replacement by a distinct controller.

The reverse-delivery race test passed 100 consecutive invocations. The final full focused suite passed 25 consecutive invocations, totaling 1,075 test executions with zero failures.

## Full macOS SwiftPM Suite

Command: the same repository-local cache configuration with unfiltered `swift test`, complete concurrency checking, and warnings as errors.

Exact final result:

```text
Test Suite 'All tests' passed.
Executed 470 tests, with 7 tests skipped and 0 failures (0 unexpected).
```

The seven skips are existing environment-gated integration cases; no NearWireUI test was skipped.

## Complete Package Gate

Command:

```sh
./Scripts/verify-package.sh
```

Exact final result:

```text
All package checks passed.
```

This gate included the structure mutation suite; Swift 5 language-mode builds for iOS 16 and macOS 13; complete concurrency and warnings-as-errors compilation; SwiftPM and CocoaPods consumer/API boundary fixtures; Core harness tests (196 passed); production TLS admission integration (1 passed); public Connect with real TLS, bidirectional events, and process lease integration (1 passed); and the complete iOS simulator suite on iPhone 17 Pro with iOS 26.4:

```text
Total: 470; Passed: 466; Skipped: 4; Failed: 0.
```

## Complete CocoaPods Gate

Command:

```sh
./Scripts/verify-podspec.sh
```

Exact final result:

```text
NearWire passed validation.
Podspec verification passed.
```

CocoaPods emitted the expected pre-release placeholder-URL warning and AppIntents metadata notes. It reported no validation failure.

## Source, Formatting, and OpenSpec

Commands and exact results:

```text
ruby Scripts/check-sdk-ui-structure.rb --self-test
NearWireUI structure mutation tests passed.

swift format lint --strict --recursive Package.swift SDK
passed with no diagnostics

git diff --check
passed with no diagnostics

DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive
Change 'sdk-ui' is valid
```
