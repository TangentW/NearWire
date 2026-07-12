# Viewer Foundation Implementation Validation

Date: 2026-07-12

## Environment

- Xcode 26.6 (build 17F113), satisfying the Xcode 16-or-later requirement.
- Apple Swift 6.3.3 compiler, with distributed and Viewer source compiled in Swift 5 language mode.
- CocoaPods 1.16.2.
- Validation host: Apple silicon macOS.

## Viewer Build Settings

Command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Release -showBuildSettings | rg '(^| )(MACOSX_DEPLOYMENT_TARGET|SWIFT_VERSION|PRODUCT_MODULE_NAME|PRODUCT_NAME|MARKETING_VERSION|CODE_SIGN_INJECT_BASE_ENTITLEMENTS|CODE_SIGN_ENTITLEMENTS) ='
```

Result: exit 0. The reported settings were:

```text
CODE_SIGN_ENTITLEMENTS = NearWireViewer/Resources/NearWireViewer.entitlements
CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO
CODE_SIGN_IDENTITY = Apple Development
CODE_SIGN_STYLE = Automatic
MACOSX_DEPLOYMENT_TARGET = 13.0
MARKETING_VERSION = 0.1.0
PRODUCT_MODULE_NAME = NearWireViewer
PRODUCT_NAME = NearWire
SWIFT_VERSION = 5.0
```

Command:

```sh
xcodebuild -workspace NearWire.xcworkspace -list
```

Result: exit 0. The root workspace resolved the repository-local NearWire package and listed `NearWireViewer` together with the existing package schemes.

## Viewer Tests

Command:

```sh
xcodebuild test -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-viewer-r6-full -clonedSourcePackagesDirPath /tmp/nearwire-viewer-r6-spm CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- ONLY_ACTIVE_ARCH=YES ARCHS=arm64
```

Latest remediation result: exit 0. `xcresulttool get test-results summary` reported 55 passed, 1 explicit stable-signer integration skip, 0 failed, and 0 expected failures.

Coverage includes real same-binary standard-login-Keychain creation, reload, nonexportability, exact `SecIdentity` assembly, TLS reset, full reset, malformed metadata, and exact foreign-certificate preservation. It also covers canonical time rejection, synchronous admission backpressure, the complete timeout-competitor table, cleanup ownership across policy removal and claim-in-progress, the combined 32-owner cap across delayed cancellation and placeholder handoff, deterministic stop-receipt ordering after slot release, same-runtime partial drain and refill, generation-scoped latest-only UI coalescing, and application lifecycle observation without timing sleeps. Security queries are non-interactive. The app-hosted XCTest scene suppresses only automatic live-runtime startup so the production identity task cannot race an isolated Keychain fixture; explicitly constructed application models retain normal behavior. Production identity preparation remains off the main actor.

The skipped update-boundary probe requires two valid, unrelated signing identities. `Documentation/Viewer-Foundation.md` records the exact A/unrelated/marker/B sequence with `set -e`, separate DerivedData directories, distinct signed bundle versions, explicit phase/build identifiers, and full signing identity/team inputs. Reserved Info.plist fields bind the phase configuration to each signed host. The XCTest rejects reused signed host hashes, versions, paths, or build identifiers, compares team, certificate, and designated-requirement fingerprints, requires the post-denial marker, and exercises exact unrelated-signer read, private-key use, reset, and delete denial before same-signer integrity and reset checks. The current validation host reports `0 valid identities found`. By explicit user decision, execution is preserved as a mandatory `release-hardening` final-system gate rather than inferred from ad-hoc output or used to block this implementation change's archive.

The forwarding guard was verified independently with a safe invalid-phase run:

```sh
xcodebuild test -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-viewer-r6-plist CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- NEARWIRE_SIGNER_PROBE_PHASE=invalid ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests/testStableSignerUpdateBoundaryProbe
```

Result: expected exit 65 with `ViewerFoundationTests.testStableSignerUpdateBoundaryProbe()` failing rather than skipping. The built signed-host Info.plist contains `NearWireSignerProbePhase=invalid`, proving that the xcodebuild setting reaches the app-hosted test through the signed product. A normal run with empty reserved fields still reports exactly one explicit skip.

## Viewer Release Product

Command:

```sh
xcodebuild -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-viewer-r3-release -clonedSourcePackagesDirPath /tmp/nearwire-viewer-r3-release-spm build CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- ONLY_ACTIVE_ARCH=YES ARCHS=arm64
```

Result: exit 0. The product was built at `/tmp/nearwire-viewer-r3-release/Build/Products/Release/NearWire.app`.

Commands:

```sh
codesign --verify --deep --strict --verbose=2 /tmp/nearwire-viewer-r3-release/Build/Products/Release/NearWire.app
codesign -d --entitlements - /tmp/nearwire-viewer-r3-release/Build/Products/Release/NearWire.app
plutil -p /tmp/nearwire-viewer-r3-release/Build/Products/Release/NearWire.app/Contents/Info.plist
plutil -p /tmp/nearwire-viewer-r3-release/Build/Products/Release/NearWire.app/Contents/Resources/PrivacyInfo.xcprivacy
otool -L /tmp/nearwire-viewer-r3-release/Build/Products/Release/NearWire.app/Contents/MacOS/NearWire
```

Results:

- Code signing verification reported `valid on disk` and `satisfies its Designated Requirement`.
- Final Release entitlements contain exactly `com.apple.security.app-sandbox=true` and `com.apple.security.network.server=true`; Release base-entitlement injection is disabled, so `get-task-allow` is absent.
- The built Info.plist reports `LSMinimumSystemVersion=13.0`, `CFBundleShortVersionString=0.1.0`, `_nearwire._tcp`, and the exact local-network usage description.
- The packaged privacy manifest declares linked Device ID for App functionality with tracking false, no tracking domains, and the single app-local UserDefaults Required Reason entry `CA92.1`.
- Dynamic linkage contains Apple system frameworks and Swift runtime libraries only. The repository-local Core package is linked into the application; there is no third-party runtime framework.

## Shared Core and SDK Regression

Command:

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-viewer-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-viewer-swiftpm swift test --disable-sandbox --quiet -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Result: exit 0. SwiftPM executed 522 tests with 0 failures; 7 environment-dependent Security/Network cases were skipped on this run.

Focused command:

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-viewer-secure-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-viewer-secure-swiftpm swift test --disable-sandbox -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --filter SecureTransportTests
```

Result: exit 0. Exactly 16 secure transport tests passed with 0 failures and 0 skips, including advertisement mapping, permission classification, the production TLS 1.3/ALPN handshake, peer-to-peer parameters, and cancel-versus-claim atomicity.

## Canonical Repository Gate

Command:

```sh
./Scripts/verify-bootstrap.sh
```

Result: exit 0 with `All bootstrap quality gates passed.` The unchanged canonical gate reported:

- 28 strict OpenSpec items passed and 0 failed;
- repository structure, English/CJK scan, version, module boundaries, package/podspec boundaries, distribution parity, and validation-tool tests passed;
- iOS 16 Swift Package source and test compilation passed;
- iOS simulator package run: 523 total, 519 passed, 4 existing environment-dependent skips, 0 failures;
- isolated Core package: 198 tests passed, 0 failures;
- real TLS active-session and public-connect integrations passed;
- CocoaPods Core, SDK, UI, and Performance consumers and public/internal boundaries passed;
- `pod lib lint` passed for NearWire 0.1.0.

Final archive-candidate rerun on 2026-07-13: the first unchanged command passed every pre-simulator gate and then failed because the restricted process could not connect to `CoreSimulatorService`. The same unchanged command was rerun with simulator-service access and exited 0. It again reported 28 strict OpenSpec items, 523 iOS Simulator tests with 519 passed and 4 existing environment skips, 198 isolated Core tests passed, both real TLS integrations passed, CocoaPods consumer boundaries passed, `NearWire passed validation.`, and `All bootstrap quality gates passed.` No validation command or script was weakened.

CocoaPods emitted the existing non-blocking placeholder URL warning for `https://example.invalid/nearwire`; validation still passed. No gate was weakened or bypassed.

An earlier run against the same source exhausted the host volume after the iOS simulator phase and exited 1 while creating the isolated Core module cache with `No space left on device`. Only temporary NearWire/Xcode build products under `/tmp` were removed. The exact unchanged command was then rerun from the beginning and produced the successful result above; no validation step or assertion was altered.

The current Round 2 remediation run first reached the simulator phase from the restricted execution environment, where `CoreSimulatorService` rejected the connection. The exact unchanged `./Scripts/verify-bootstrap.sh` command was rerun with simulator-service access and passed from the beginning. No script, test, threshold, or assertion was changed. The successful rerun reported 523 iOS simulator cases with 519 passed, 4 existing environment-dependent skips, and 0 failures; the isolated Core run passed 198 tests; both real TLS integrations passed; and CocoaPods lint completed with only the existing placeholder URL warning.

## Formatting, Diff, and OpenSpec

Commands:

```sh
swift format lint --strict --recursive Viewer/NearWireViewer Viewer/NearWireViewerTests Core/Sources/NearWireTransport/SecureByteChannel.swift Core/Sources/NearWireTransport/SecureTransportPrimitives.swift Core/Tests/NearWireTransportTests/SecureTransportTests.swift SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift
git diff --check
DO_NOT_TRACK=1 openspec validate viewer-application-foundation --strict
```

Results: all commands exited 0. OpenSpec reported `Change 'viewer-application-foundation' is valid`.
