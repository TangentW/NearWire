# Implementation Review Round 2: Security, Performance, and Documentation

## Scope and Verdict

This fresh review re-read the complete active `viewer-application-foundation` artifacts, all current Viewer and changed Core source, tests, documentation, metadata, entitlements, privacy manifest, validation evidence, the three Round 1 implementation reports, and the Round 1 remediation record. It independently rebuilt and tested the current worktree and inspected the resulting Release product.

The Round 1 fixes materially improve the foundation. The pre-MainActor 32-slot generation gate, claim/cancellation revalidation, complete certificate-ownership proof, zero-configuration login-Keychain lifecycle evidence, deterministic deadlines, and bounded cleanup receipt are present. However, four new or incompletely covered actionable findings remain, so Round 2 approval is withheld.

**Unresolved actionable finding count: 4 (1 High, 3 Medium).**

## Round 1 Finding Recheck

| Round 1 finding | Round 2 result |
| --- | --- |
| `NW-SPD-001`: admission capacity was applied after an unbounded MainActor hop | **Core ingress defect resolved.** Incoming listener events now synchronously enter `ViewerListenerAdmissionIngress`, reserve through the manager before claim, and reject stale/full work without a MainActor task. Claim completion is revalidated against the exact attempt and active generation. The pending-UI portion is not fully resolved; see `NW-SPD2-002`. |
| `NW-SPD-002`: production persistent identity path had no successful evidence | **Evidence gap resolved by an explicit product decision.** The active contract now uses the standard per-user login Keychain for ad-hoc/local zero-configuration operation. The independently repeated Viewer suite completed 44 tests with no failures or skips, including real login-Keychain identity creation, reload, nonexportability, `SecIdentity` assembly, and both reset scopes. The non-interactive query guarantee is still incomplete; see `NW-SPD2-003`. |
| `NW-SPD-003`: reset could delete a foreign certificate referenced by metadata | **Resolved.** `validateOwnedTLSMetadata` now requires the fixed certificate profile, self-signature/trust, complete metadata digests, and correspondence with the exact tagged private key before deletion. Injected adversarial and real foreign-certificate tests pass. |

## Findings

### NW-SPD2-001 — High — Pre-Hello channel events can accumulate without a count or byte bound

**Evidence**

- `ViewerAdmissionConnectionCore.receive` creates one asynchronous block for every channel event at `Viewer/NearWireViewer/Admission/ViewerAdmission.swift:229-231`. It has no pending-event count, pending-byte accounting, synchronous backpressure, or overflow cancellation.
- Core invokes the Viewer event handler synchronously for received bytes at `Core/Sources/NearWireTransport/SecureByteChannel.swift:245-276`, but immediately requests the next network receive after that handler returns. The Viewer handler returns after merely enqueueing work, not after decoding it.
- Therefore, Network/Core production can continue accepting bounded individual chunks while the per-connection Viewer queue retains an unbounded number of `Data` values and closures waiting to reach the bounded `WireFrameDecoder`.
- The 32-slot capacity and 10-second deadline at `Viewer/NearWireViewer/Admission/ViewerAdmission.swift:408-410` bound connection count and duration, but not bytes retained during those ten seconds. Up to 32 unauthenticated nearby peers can exercise this path concurrently.
- Existing admission tests cover oversized/malformed frames, coalesced input, deadlines, and the 32/33 connection edge, but none blocks the connection-core consumer while flooding receive events and measures queued count or bytes.
- This contradicts the bounded pre-session requirement at `openspec/changes/viewer-application-foundation/specs/viewer-application-foundation/spec.md:101-109` and the resource-bound claims at `openspec/changes/viewer-application-foundation/design.md:63-73`.

**Impact**

A peer does not need a valid App Hello or authenticated identity. It can stream data after TLS readiness faster than the Viewer connection queue decodes it. Per-frame and per-read limits do not bound already queued chunks, so memory and task/closure retention can grow with network throughput until timeout or process exhaustion. The 32-slot gate multiplies rather than eliminates this byte-retention exposure.

**Required action**

Make channel-to-admission delivery backpressured or give it a hard pending-event and pending-byte budget. The simplest safe shape is to process the already serialized channel callback synchronously through the connection core, provided lock/queue reentrancy is proven; otherwise use a bounded mailbox that atomically owns each `Data` value and cancels the connection on overflow. The terminal event must not be stranded behind an attacker-controlled unbounded queue. Add a deterministic test that suspends or gates decoding, emits substantially more chunks than the configured bound, and proves retained event count and bytes never exceed the bound, overflow selects one terminal cancellation, the deadline remains effective, and cleanup releases all retained data.

### NW-SPD2-002 — Medium — The latest-only MainActor coalescer can monopolize the MainActor indefinitely

**Evidence**

- `ViewerPendingCoalescer.submit` correctly stores only one latest snapshot and creates at most one task at `Viewer/NearWireViewer/Application/ViewerRuntimeDependencies.swift:141-163`.
- Its MainActor drain uses an unsuspended `while true` loop at `Viewer/NearWireViewer/Application/ViewerRuntimeDependencies.swift:165-177`. If background admission churn keeps replacing `latest` before each check, that one task never yields to SwiftUI, window lifecycle, pause, or recovery actions.
- The remediation record claims `testListenerAdmissionIngressBoundsBurstBeforeMainActorWork` proves bounded UI delivery (`openspec/changes/viewer-application-foundation/evidence/implementation-round1-remediation.md:17`), but the test at `Viewer/NearWireViewerTests/ViewerFoundationTests.swift:1138-1171` constructs `ViewerAdmissionManager(onPending: { _ in })` and never instantiates or exercises `ViewerPendingCoalescer`.
- The active requirement promises latest-only publication with at most one MainActor drain task per burst at `openspec/changes/viewer-application-foundation/specs/viewer-application-foundation/spec.md:107`, but it does not justify an unbounded amount of work inside that one task.

**Impact**

Connection and terminal churn is produced on background queues. A sustained producer can keep the MainActor loop nonempty even though memory is bounded to one snapshot, causing UI starvation and elevated CPU/power use. The implementation exchanges the Round 1 task-count denial of service for a single-task fairness denial of service.

**Required action**

Deliver a bounded number of snapshots per MainActor turn, preferably one latest snapshot, then atomically reschedule at most one later drain if a newer snapshot arrived. Include an explicit suspension or new MainActor scheduling turn so other UI and lifecycle work can run. Add a coalescer-specific stress test with a continuous producer and a MainActor heartbeat; prove one latest snapshot is retained, at most one drain is scheduled, stale snapshots are dropped, the heartbeat progresses, and the final snapshot is eventually delivered.

### NW-SPD2-003 — Medium — The documented non-interactive, exact-Keychain guarantee is not implemented on every path

**Evidence**

- `nonInteractiveQuery` always installs `kSecUseAuthenticationUISkip` at `Viewer/NearWireViewer/Identity/ViewerIdentityStore.swift:391-397`.
- That helper is valid for the `SecItemCopyMatching` calls, but it is also passed to `SecItemDelete` for generic passwords, private keys, and certificates at `Viewer/NearWireViewer/Identity/ViewerIdentityStore.swift:431-445`, `Viewer/NearWireViewer/Identity/ViewerIdentityStore.swift:495-504`, and `Viewer/NearWireViewer/Identity/ViewerIdentityStore.swift:586-606`.
- The Xcode SDK's `Security.framework/Headers/SecItem.h:1061-1080` explicitly states that `kSecUseAuthenticationUISkip` can be used only with `SecItemCopyMatching`; `kSecUseAuthenticationUIFail` is the value that fails when an item would require UI. A happy-path delete succeeding on the review host does not establish macOS 13 compatibility or prompt suppression for an authentication-required item.
- If the exact non-interactive identity query fails, `copyIdentity` falls back to `SecIdentityCreateWithCertificate(nil, ...)` at `Viewer/NearWireViewer/Identity/ViewerIdentityStore.swift:609-632`. Apple's [`SecIdentityCreateWithCertificate`](https://developer.apple.com/documentation/security/secidentitycreatewithcertificate%28_%3A_%3A_%3A%29) documentation says a `nil` keychain argument searches the user's default keychain search list. This path has neither the exact query selectors nor an authentication-UI control.
- Apple documents that authentication UI is allowed by default when `kSecUseAuthenticationUI` is absent ([`kSecUseAuthenticationUI`](https://developer.apple.com/documentation/security/ksecuseauthenticationui)). The design and user documentation nevertheless claim that identity assembly and deletes explicitly suppress UI at `openspec/changes/viewer-application-foundation/design.md:47-49` and `Documentation/Viewer-Foundation.md:27-38`.
- The 44-test real Keychain lifecycle exercises the available happy path on macOS 26.5.1. It does not force an authentication-required item, a locked/alternate keychain, primary identity-query failure, or the macOS 13 behavior of the unsupported delete value.

**Impact**

Automatic startup or destructive recovery can behave differently across Keychain state and supported macOS versions: fail with a parameter/interaction error, search outside the intended exact path, or potentially present UI despite the product's fail-closed promise. Reset remains ownership-safe, but availability and zero-configuration behavior are not proven on these branches.

**Required action**

Use operation-specific Security dictionaries: `Skip` only for `SecItemCopyMatching`, and a supported fail-without-UI mechanism for deletes, such as `kSecUseAuthenticationUIFail` or a noninteractive `LAContext` appropriate to the deployment target. Remove the broad `SecIdentityCreateWithCertificate(nil, ...)` fallback, or constrain identity assembly to the exact intended Keychain and re-verify the returned private key against the already validated owned key without any UI-capable path. Add an injectable Security-operation seam or equivalent tests that assert every production query dictionary, simulate interaction-required results, force primary identity-query failure, and verify no fallback search, prompt-capable operation, or raw OSStatus reaches the UI.

### NW-SPD2-004 — Medium — The privacy manifest omits the required reason for direct `UserDefaults` use

**Evidence**

- The production preference implementation directly reads and writes `UserDefaults.standard` at `Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:416-423`.
- The source and packaged `PrivacyInfo.xcprivacy` contain no `NSPrivacyAccessedAPITypes` entry (`Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy:1-23`). The packaging test affirmatively requires that key to be absent at `Viewer/NearWireViewerTests/ViewerFoundationTests.swift:274-303`.
- The design states that no planned API requires a reason at `openspec/changes/viewer-application-foundation/design.md:114-120`, the evidence celebrates no Required Reason entries at `openspec/changes/viewer-application-foundation/evidence/implementation-validation.md:72-78`, and the operator documentation repeats the claim at `Documentation/Viewer-Foundation.md:70-74`.
- Apple marks `UserDefaults` as a required-reason API and directs apps to declare its use in `PrivacyInfo.xcprivacy` ([UserDefaults documentation](https://developer.apple.com/documentation/foundation/userdefaults)). Apple's [TN3183](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest) identifies `NSPrivacyAccessedAPICategoryUserDefaults`; `CA92.1` is the documented reason for app-only preferences such as this approval setting.

**Impact**

The bundled manifest is syntactically valid but semantically incomplete. Distribution validation can warn or reject the product, and the spec, test, evidence, and documentation currently enforce the wrong privacy assertion.

**Required action**

Add `NSPrivacyAccessedAPITypes` with `NSPrivacyAccessedAPICategoryUserDefaults` and the approved reason that exactly matches the app-only approval preference, currently `CA92.1`. Update the capability spec, design, documentation, packaging test, and evidence to distinguish required declared use from unused categories. Add a source-to-manifest audit for required-reason APIs so future Viewer APIs cannot silently drift from the packaged manifest.

## Verified Boundaries

- Incoming wrappers now cross a synchronous active-generation and shared 32-slot gate before any MainActor task or channel claim. The 33rd wrapper is immediately rejected; claim completion cannot survive generation cancellation or pause/resume.
- Destructive identity reset validates the complete certificate/key/metadata ownership tuple before certificate deletion. Foreign and unverifiable certificates remain preserved.
- Identity load, reset, and certificate work run away from the MainActor. The one-second cleanup wait is bounded, admission remains closed after timeout, and the same cleanup owner continues eventual cancellation.
- TLS remains mandatory TLS 1.3 with NearWire ALPN and peer-to-peer routing. There is no plaintext or identity-free Viewer listener path.
- UI and documentation truthfully state `TLS encrypted; Viewer identity is not authenticated.` They also state that pairing code and stable `vid` are Bonjour-visible identifiers, not passwords or secrets.
- Errors remain fixed closed categories; no raw Network error, OSStatus, endpoint, certificate material, wire bytes, or peer-provided diagnostic string is rendered or logged.
- The independently built Release application is ad-hoc signed and verifies successfully. Its final entitlements contain exactly App Sandbox and `com.apple.security.network.server`; Info.plist contains macOS 13 minimum, `_nearwire._tcp`, and the exact local-network purpose string. Dynamic linkage contains Apple frameworks and Swift runtime libraries only.
- The privacy manifest's Device ID, linked, App Functionality, and tracking-false declarations match the current `vid` and Viewer Hello behavior. Finding `NW-SPD2-004` is limited to the missing required-reason API declaration.

## Validation Performed

All commands were run from the repository root on 2026-07-12.

1. `xcodebuild -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination platform=macOS,arch=arm64 -derivedDataPath /tmp/nearwire-viewer-r2-security-dd -clonedSourcePackagesDirPath /tmp/nearwire-viewer-r2-security-spm test CODE_SIGN_IDENTITY=- ONLY_ACTIVE_ARCH=YES ARCHS=arm64`
   - Result: exit 0.
   - Independent `xcresulttool` summary: 44 passed, 0 failed, 0 skipped, 0 expected failures.
2. `swift test --disable-sandbox -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --filter SecureTransportTests` with temporary module caches.
   - Result: exit 0; 16 passed, 0 failed, 0 skipped.
3. `xcodebuild -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -configuration Release -destination platform=macOS,arch=arm64 -derivedDataPath /tmp/nearwire-viewer-r2-security-release -clonedSourcePackagesDirPath /tmp/nearwire-viewer-r2-security-release-spm build CODE_SIGN_IDENTITY=- ONLY_ACTIVE_ARCH=YES ARCHS=arm64`
   - Result: exit 0.
   - `codesign --verify --deep --strict --verbose=2`: valid on disk and satisfies its Designated Requirement.
   - `codesign -d --entitlements -`: exactly App Sandbox and incoming network server.
   - `plutil -p` confirmed final Info.plist and packaged privacy values; `otool -L` found no third-party runtime library.
4. `DO_NOT_TRACK=1 openspec validate viewer-application-foundation --strict --no-interactive`
   - Result: exit 0; the change is structurally valid.
5. `plutil -lint Viewer/NearWireViewer/Resources/Info.plist Viewer/NearWireViewer/Resources/NearWireViewer.entitlements Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy`
   - Result: exit 0 for all three files. This validates plist syntax, not semantic required-reason coverage.
6. `./Scripts/verify-english.sh`
   - Result: exit 0.
7. `git diff --check`
   - Result: exit 0.

## Completion Gate

Round 2 security/performance/documentation approval is withheld. Resolve all four findings, add deterministic queue-retention, MainActor-fairness, non-interactive Keychain, and privacy-manifest coverage, update inaccurate evidence and documentation, rerun the canonical gates, and request a fresh independent review. A future round must establish zero unresolved actionable findings independently.
