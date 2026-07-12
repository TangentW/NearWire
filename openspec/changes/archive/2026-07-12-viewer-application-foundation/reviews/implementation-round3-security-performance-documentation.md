# Implementation Review Round 3: Security, Performance, and Documentation

## Scope and Verdict

This fresh review re-read all active `viewer-application-foundation` artifacts, current worktree changes, Viewer and changed Core source, tests, resources, documentation, validation evidence, the Round 2 implementation reports, and `evidence/implementation-round2-remediation.md`. It independently repeated focused tests and produced and inspected a fresh Release application.

All four Round 2 findings are closed in their immediate implementation scope. Pre-Hello input is synchronously backpressured, pending-summary delivery is fair and generation-scoped, Security queries use a non-interactive exact path without the broad identity fallback, and the privacy manifest contains the app-local UserDefaults reason. The fresh audit nevertheless found two unresolved cross-cutting resource and deployment findings. Round 3 approval is therefore withheld.

**Unresolved actionable finding count: 2 (1 High, 1 Medium).**

## Round 2 Finding Recheck

| Round 2 finding | Round 3 result |
| --- | --- |
| `NW-SPD2-001`: unbounded pre-Hello event queue | **Resolved.** `ViewerAdmissionConnectionCore.receive` synchronously enters its private serial queue at `Viewer/NearWireViewer/Admission/ViewerAdmission.swift:242-248`. Core cannot request the next receive until decoding returns. The gated test at `Viewer/NearWireViewerTests/ViewerFoundationTests.swift:716-747` proves callback backpressure. |
| `NW-SPD2-002`: MainActor coalescer could monopolize the actor | **Resolved.** `ViewerPendingCoalescer` retains one latest snapshot, delivers one snapshot per yielded MainActor turn, reschedules only when newer data exists, and supports synchronous deactivation at `Viewer/NearWireViewer/Application/ViewerRuntimeDependencies.swift:143-203`. Each runtime owns a token-guarded coalescer and deactivates it before admission stop at `Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:135-152` and `Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:180-198`. The focused fairness/generation test passes. |
| `NW-SPD2-003`: non-interactive Keychain operations were incomplete | **Immediate query defect resolved.** `ViewerIdentityStore.nonInteractiveQuery` now supplies an `LAContext` with interaction disabled to exact reads, existence checks, identity lookup, and deletes at `Viewer/NearWireViewer/Identity/ViewerIdentityStore.swift:382-400` and `Viewer/NearWireViewer/Identity/ViewerIdentityStore.swift:402-645`. The default-Keychain identity fallback is gone, and the returned identity's key is compared with the already validated owned key. A separate ad-hoc signing persistence problem remains; see `NW-SPD3-001`. |
| `NW-SPD2-004`: UserDefaults Required Reason was absent | **Resolved.** `Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy:5-15` declares exactly `NSPrivacyAccessedAPICategoryUserDefaults` with `CA92.1`. The packaged Release resource matches, the packaging test requires the exact entry, and the spec/design/operator documentation are consistent. |

## Findings

### NW-SPD3-001 — High — Ad-hoc signing does not establish persistent non-interactive login-Keychain access across Viewer updates

**Evidence**

- The active contract says the standard per-user macOS login Keychain is a zero-configuration store that works for an ad-hoc/local signed Viewer (`openspec/changes/viewer-application-foundation/specs/viewer-application-foundation/spec.md:27-33`, `openspec/changes/viewer-application-foundation/design.md:39-49`, and `Documentation/Viewer-Foundation.md:25-38`).
- Both Debug and Release configurations hard-code manual ad-hoc signing with `CODE_SIGN_IDENTITY = "-"` at `Viewer/NearWireViewer.xcodeproj/project.pbxproj:169-175`.
- The real lifecycle test at `Viewer/NearWireViewerTests/ViewerFoundationTests.swift:482-520` creates and reloads isolated file-based Keychain items in one Debug test-host binary. It does not launch a second build, updated binary, or Release application against records created by the first designated requirement.
- Independent inspection of the fresh products showed different ad-hoc designated requirements for the same bundle identifier: Debug was `cdhash H"4e361dc417cd48685975af81d2a3a2abef071a6e"`, while Release was `cdhash H"07036d4abf2d7ee724a565d392b5e624ed8d461c"`. Any source or signed-resource update can likewise change the ad-hoc CodeDirectory hash.
- Apple's [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) explains that the file-based Keychain uses ACLs, unlike data-protection access groups. In a directly relevant Apple DTS answer, the engineer states that this legacy access control is centered on code-signing requirements, requires a stable signing identity, and specifically recommends proving that an updated app can still access an earlier version's item ([Apple Developer Forums](https://developer.apple.com/forums/thread/809954)).
- The new non-interactive `LAContext` correctly prevents a prompt; it cannot make a changed ad-hoc cdhash satisfy an ACL created for the earlier binary. When access is denied, load and reset fail closed, potentially leaving the Viewer unable to reuse or delete its exact persistent key.
- The recorded 53-test result and requirement-to-evidence audit claim ad-hoc zero-configuration persistence is proven (`openspec/changes/viewer-application-foundation/evidence/implementation-validation.md:40-50` and `openspec/changes/viewer-application-foundation/evidence/requirement-to-evidence-audit.md:14-18`), but the cross-build condition central to that claim is absent.

**Impact**

The internal development workflow rebuilds the Viewer as code changes. A rebuilt ad-hoc application may be treated as a different program by the login-Keychain ACL. With authentication interaction deliberately disabled, the new build can fail identity load; and because reset uses the same inaccessible selectors, both Retry and reset recovery can fail. The listener and Bonjour publication then remain unavailable until a team member manually repairs Keychain state, contradicting the zero-configuration and persistent-identity goals.

This finding is about deployment identity and persistence, not the cryptographic correctness of the generated P-256 key or certificate.

**Required action**

Choose and document a stable signing strategy for the maintained Viewer, such as a team-controlled Apple Development or Developer ID identity appropriate to internal distribution, and stop treating an ad-hoc Release build as proof of persistent login-Keychain compatibility. Add an update-boundary integration gate that:

1. runs build A to create the production-selector identity and complete a real TLS signing operation;
2. runs independently signed build B, representing the supported update path, without deleting Keychain state;
3. proves non-interactive identity reload, the same installation/TLS identity, actual TLS private-key use, TLS-only reset, and full reset; and
4. proves an unrelated signer cannot access or delete the records.

If the product must remain ad-hoc signed, revise the persistence and zero-configuration requirements and select a storage/recovery model whose security and upgrade behavior can actually be guaranteed. Do not weaken the ACL to allow arbitrary applications merely to preserve ad-hoc convenience.

### NW-SPD3-002 — Medium — Post-terminal cleanup and placeholder handoff ownership are outside every hard resource cap

**Evidence**

- Active admission is limited to 32 reservations, but `finish` releases each reservation before asynchronous core cleanup completes at `Viewer/NearWireViewer/Admission/ViewerAdmission.swift:904-912`.
- Successful automatic or manual handoff also releases the reservation before the placeholder owner finishes cancelling the accepted handle at `Viewer/NearWireViewer/Admission/ViewerAdmission.swift:915-923`.
- `ViewerAdmissionCleanupRegistry` retains an unbounded `[UUID: ViewerAdmissionAttemptCleanup]` dictionary at `Viewer/NearWireViewer/Admission/ViewerAdmission.swift:411-450`. `ViewerPlaceholderHandoffOwner` independently retains an unbounded `Set<UUID>` and one unstructured task per accepted handle at `Viewer/NearWireViewer/Admission/ViewerAdmission.swift:536-595`.
- The manager intentionally retains claim-in-progress, already-cancelling, and late-channel ownership after releasing the admission slot. The active requirement records this behavior at `openspec/changes/viewer-application-foundation/specs/viewer-application-foundation/spec.md:105-111` but defines no cleanup-owner, task, or handed-off-placeholder cap.
- The new tests explicitly demonstrate that one cancellation or handoff cleanup may remain outstanding beyond the one-second bounded wait (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:1349-1548`). They prove ownership correctness for one attempt at a time, but do not run repeated waves while cancellation is gated and assert a global retained-owner bound.
- Default policy automatically accepts a syntactically valid App Hello. The pairing code is intentionally public nearby metadata and Viewer identity is not authenticated, so a nearby protocol-capable peer can repeatedly reach the handoff path without user approval.

**Impact**

The 32-slot admission limit bounds only current policy state. If cancellation or placeholder cleanup is delayed, successive timeout/replacement/pause waves or rapid valid automatic handoffs can release those slots and admit new work while old connection cores, channels, serial queues, tasks, registry entries, and owner IDs remain retained. The one-second receipt bounds how long UI lifecycle waits; it does not bound retained cleanup work. Under sustained churn or scheduler pressure, memory and task count can grow beyond the advertised connection bound and amplify denial-of-service conditions.

**Required action**

Add one runtime-wide hard cap covering active attempts plus cleanup-in-progress and placeholder-owned handles, or retain the admission reservation until the associated cleanup owner has completed. If active handoffs must be accounted separately for future session management, the foundation placeholder still needs its own finite cap and synchronous overflow rejection. Preserve the cleanup receipt and exact ownership while ensuring new admission cannot create more retained per-connection owners or tasks than the chosen bound.

Add a deterministic multi-wave test that gates cancellation, repeatedly fills and terminates or hands off attempts, and proves:

- total retained attempts, cleanup owners, placeholder handles, queues, and cleanup tasks never exceed the hard cap;
- excess incoming wrappers are rejected before claim;
- opening the gate drains every owner exactly once; and
- stop's single receipt completes without leaked ownership.

Update documentation and the requirement-to-evidence audit to state the combined resource bound rather than describing only the 32 active admission slots.

## Verified Security, Performance, Privacy, and Documentation Boundaries

- Pre-Hello data is synchronously backpressured through one continuous connection core and bounded decoder. No second per-connection receive-event queue remains.
- Listener ingress still reserves one of 32 active slots before channel claim and rejects stale, paused, stopped, or over-capacity wrappers without a MainActor task. Claim completion cannot reinsert after generation cancellation.
- Pending-summary publication retains one latest snapshot, yields between MainActor deliveries, deactivates synchronously on stop, and guards delivery with the exact runtime token.
- Destructive identity reset validates the complete certificate/key/metadata ownership tuple before certificate deletion. The broad default-Keychain identity fallback is absent, and exact Security queries fail without authentication UI.
- TLS 1.3, NearWire ALPN, connection-local certificate validation, and peer-to-peer routing remain mandatory. There is no plaintext or identity-free listener path.
- The UI and English operator documentation truthfully state `TLS encrypted; Viewer identity is not authenticated.` Pairing code and stable `vid` are described as Bonjour-visible identifiers, not passwords or secrets.
- Errors remain closed fixed categories. No raw Network error, OSStatus, endpoint, certificate/private-key material, wire bytes, or peer-provided diagnostic text is logged or rendered.
- Identity creation, validation, and reset remain off the MainActor. Pairing generation and listener collision retry are bounded.
- The fresh Release application verifies as correctly signed for its ad-hoc identity. Final entitlements contain exactly App Sandbox and incoming network server; Info.plist contains macOS 13 minimum, `_nearwire._tcp`, and the exact local-network purpose string. Dynamic linkage contains only Apple frameworks and Swift runtime libraries.
- The packaged privacy manifest declares linked Device ID for App Functionality, tracking false, no tracking domains, and exactly the app-local UserDefaults category with `CA92.1`. No other Viewer production source directly references a required-reason API identified by the current audit.
- Documentation does not claim Event transfer, persistent history, search/export, multi-device active session management, or performance dashboards are implemented by this foundation.

## Validation Performed

All commands were run from the repository root on 2026-07-12.

1. `xcodebuild -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination platform=macOS,arch=arm64 -derivedDataPath /tmp/nearwire-viewer-r3-security-dd -clonedSourcePackagesDirPath /tmp/nearwire-viewer-r3-security-spm test CODE_SIGN_IDENTITY=- ONLY_ACTIVE_ARCH=YES ARCHS=arm64`
   - Result: exit 0.
   - Independent `xcresulttool` summary: 53 passed, 0 failed, 0 skipped, 0 expected failures.
2. `swift test --disable-sandbox -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --filter SecureTransportTests` with temporary module caches.
   - Result: exit 0; 16 passed, 0 failed, 0 skipped.
3. `xcodebuild -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -configuration Release -destination platform=macOS,arch=arm64 -derivedDataPath /tmp/nearwire-viewer-r3-security-release -clonedSourcePackagesDirPath /tmp/nearwire-viewer-r3-security-release-spm build CODE_SIGN_IDENTITY=- ONLY_ACTIVE_ARCH=YES ARCHS=arm64`
   - Result: exit 0.
   - `codesign --verify --deep --strict --verbose=2`: valid on disk and satisfies its current Designated Requirement.
   - `codesign -d --entitlements -`: exactly App Sandbox and incoming network server.
   - `plutil -p`: final Info.plist and privacy manifest match the source resources.
   - `otool -L`: Apple system frameworks and Swift runtime libraries only.
   - `codesign -d -r-`: fresh Debug and Release products use different ad-hoc cdhash designated requirements despite the same bundle identifier.
4. `DO_NOT_TRACK=1 openspec validate viewer-application-foundation --strict --no-interactive`
   - Result: exit 0; the change is structurally valid.
5. `plutil -lint Viewer/NearWireViewer/Resources/Info.plist Viewer/NearWireViewer/Resources/NearWireViewer.entitlements Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy`
   - Result: exit 0 for all three resources.
6. `./Scripts/verify-english.sh`
   - Result: exit 0.
7. `git diff --check`
   - Result: exit 0.

## Completion Gate

Round 3 security/performance/documentation approval is withheld. Resolve both findings, add stable-signer update-boundary Keychain/TLS evidence and a combined post-terminal ownership cap, correct affected requirements/evidence/documentation, rerun all canonical gates, and request another fresh independent review. Approval requires zero unresolved actionable findings.
