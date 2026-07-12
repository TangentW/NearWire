# Implementation Review Round 1: Security, Performance, and Documentation

## Scope and Verdict

This review independently inspected the active proposal, design, capability specification, task list, implementation evidence, complete current worktree diff, Viewer and changed Core source, application metadata, entitlements, privacy manifest, documentation, and tests for `viewer-application-foundation`.

The implementation has good closed diagnostic categories, mandatory TLS/ALPN enforcement, bounded wire decoding, exact Bonjour metadata, narrow sandbox entitlements, a truthful privacy manifest, and accurate UI wording about unauthenticated Viewer identity. It is not ready for completion review because three actionable findings remain.

**Unresolved actionable finding count: 3 (2 High, 1 Medium).**

## Findings

### NW-SPD-001 — High — The 32-slot admission limit is applied after an unbounded MainActor task queue

**Evidence**

- `Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:235-240` creates a new unstructured `Task { @MainActor ... }` for every listener event. An `.incoming` event and its connection wrapper are therefore retained by a task before any capacity decision occurs.
- The task reaches the incoming branch only at `Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:247-271`; the first budget reservation is later still, at `Viewer/NearWireViewer/Admission/ViewerAdmission.swift:327-338`.
- `Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:37-40` and `Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:127-130` also create one MainActor task per pending-list publication. Terminal and timeout paths publish even when no attempt was removed at `Viewer/NearWireViewer/Admission/ViewerAdmission.swift:446-461`, allowing stale or repeated terminal traffic to enqueue redundant full-array updates.
- The direct manager test at `Viewer/NearWireViewerTests/ViewerFoundationTests.swift:866-905` proves that `ViewerAdmissionManager.admit` rejects its 33rd direct call before channel claim, but it does not exercise the actual listener-callback-to-MainActor ingress edge.
- The requirement says the slot is reserved before claiming the wrapper or starting per-connection work and that connection 33 creates no channel, decoder task, deadline task, or UI row (`openspec/changes/viewer-application-foundation/specs/viewer-application-foundation/spec.md:95-103`). The design repeats that it creates no task (`openspec/changes/viewer-application-foundation/design.md:63-75`), and the operator documentation states that the 33rd connection is rejected before deadline work (`Documentation/Viewer-Foundation.md:42-55`). Those statements are not true at the application ingress boundary.

**Impact**

A nearby peer can open connections faster than the MainActor drains listener events. Every arrival then allocates a task and retains its incoming wrapper outside the advertised 32-slot bound. The queue is limited only by process memory and scheduler pressure, so the documented resource-exhaustion control can be bypassed before `ViewerAdmissionManager` sees the connection. Pending-list task fan-out adds avoidable MainActor and copying pressure during churn.

**Required action**

Reserve or reject synchronously at the serialized listener callback edge, before creating a task, channel, decoder, deadline, or other per-connection object. A rejected wrapper must be cancelled synchronously. Carry a reserved, generation-bound admission token into the isolated state transition, and make generation invalidation atomic so an old-generation reservation cannot be installed after replacement cancellation. Coalesce pending-list delivery to latest state and avoid publishing unchanged state. Add an application-edge burst test that deliberately blocks the MainActor, emits more than 32 incoming events, and proves that only 32 wrappers/reservations and bounded callback work exist while every excess wrapper is immediately cancelled.

### NW-SPD-002 — High — The production data-protection Keychain and persistent `SecIdentity` path has no successful release evidence

**Evidence**

- The only end-to-end identity lifecycle test catches `identityUnavailable` and skips at `Viewer/NearWireViewerTests/ViewerFoundationTests.swift:473-508`. That test is intended to cover creation, reload, nonexportability, TLS-only reset, and full reset.
- Its isolated selectors explicitly disable the data-protection Keychain at `Viewer/NearWireViewer/Identity/ViewerIdentityStore.swift:33-38`, whereas production enables it at `Viewer/NearWireViewer/Identity/ViewerIdentityStore.swift:20-25`. A successful isolated run would therefore still not prove the live selector path.
- The foreign-certificate fixture test also skips when the host cannot create its certificate at `Viewer/NearWireViewerTests/ViewerFoundationTests.swift:557-599`.
- The checked-in project forces manual ad-hoc signing for Debug and Release at `Viewer/NearWireViewer.xcodeproj/project.pbxproj:169-175`. The recorded Release build likewise overrides `CODE_SIGN_IDENTITY=-` at `openspec/changes/viewer-application-foundation/evidence/implementation-validation.md:57-65`.
- The evidence explicitly records zero valid signing identities and both skipped tests at `openspec/changes/viewer-application-foundation/evidence/implementation-validation.md:40-55`. It proves compilation, packaging, and static selectors, but it does not prove that the released app can assemble the persistent `SecIdentity`, adapt it to Network.framework, and reach listener publication.
- Nevertheless, identity lifecycle and validation coverage tasks are checked complete at `openspec/changes/viewer-application-foundation/tasks.md:12-16` and `openspec/changes/viewer-application-foundation/tasks.md:24-29`.

**Impact**

Persistent identity is a hard startup dependency. A signing, sandbox ACL, data-protection Keychain, certificate association, or `SecIdentity` lookup failure prevents the Viewer from publishing Bonjour or accepting any connection. Current green builds can therefore coexist with a completely nonfunctional signed product. This is a release-blocking evidence gap, not proof that the implementation necessarily fails under an appropriate development/distribution identity.

**Required action**

Run a development- or distribution-signed sandboxed Viewer/test host using the live data-protection Keychain configuration and capture evidence for creation, successful `SecIdentity` assembly, Core transport adaptation or a real TLS listener/handshake, process relaunch reuse, nonexportability, renewal, TLS-only reset, full reset, and foreign-item preservation. These checks must fail the gate when unavailable rather than becoming skips. If an appropriate signing environment is not available, leave the affected tasks incomplete and describe the release gate as blocked instead of treating ad-hoc build success as identity-runtime evidence.

### NW-SPD-003 — Medium — Reset can delete a foreign certificate referenced by corrupted or tampered metadata

**Evidence**

- Normal loading retrieves the metadata-referenced certificate, checks certificate hash and serial, loads the exact tagged private key, validates certificate/key correspondence, and checks the public-key hash at `Viewer/NearWireViewer/Identity/ViewerIdentityStore.swift:143-175`.
- On an invalid load, automatic repair calls the same reset helper at `Viewer/NearWireViewer/Identity/ViewerIdentityStore.swift:72-90`; both explicit reset scopes also use it at `Viewer/NearWireViewer/Identity/ViewerIdentityStore.swift:99-118`.
- Before deleting a referenced certificate, `resetTLSInternal` checks only metadata version, certificate hash, and serial at `Viewer/NearWireViewer/Identity/ViewerIdentityStore.swift:238-273`. It does not verify the stored `publicKeyHash`, extract and compare the certificate public key, or prove correspondence with the exact owned private key.
- Consequently, metadata that references a real foreign certificate and contains that certificate's hash and serial authorizes deletion even though normal load rejects the key mismatch.
- The existing foreign-item test covers only a certificate with no metadata reference (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:557-599`), not adversarial metadata that points to the foreign certificate; that test was also skipped in the recorded and independently repeated runs.
- This contradicts the foreign-item preservation requirement at `openspec/changes/viewer-application-foundation/specs/viewer-application-foundation/spec.md:21-27` and `openspec/changes/viewer-application-foundation/specs/viewer-application-foundation/spec.md:51-54`, the owned-key condition at `openspec/changes/viewer-application-foundation/design.md:39-49`, and the documentation claim at `Documentation/Viewer-Foundation.md:25-38`.

**Impact**

Corruption, a partial write, or same-context metadata tampering can turn automatic repair or either reset action into deletion of a certificate not owned by NearWire. The lookup remains narrow, but the ownership decision is incomplete.

**Required action**

Before certificate deletion, require all metadata fields to validate and require the referenced certificate's public key to match both `publicKeyHash` and the exact owned tagged private key. If any proof is missing or mismatched, preserve the certificate and fail closed or leave it as an orphan while removing only selectors that are independently proven to be owned. Add an adversarial test whose syntactically valid metadata references a real foreign certificate with matching stored certificate hash and serial but a mismatched owned key; prove that automatic repair, TLS-only reset, and full reset never delete that certificate.

## Verified Security, Privacy, Performance, and Documentation Boundaries

- TLS remains mandatory TLS 1.3 with the NearWire ALPN; the focused Core transport tests cover TLS downgrade, ALPN mismatch, advertisement validation, peer-to-peer parameters, cancellation/claim atomicity, and closed local-network permission classification.
- Viewer presentation maps failures to fixed categories and does not forward raw Network or Security diagnostics. UI and documentation correctly state that transport is encrypted but Viewer identity is not authenticated, and that the pairing code and `vid` are nearby-visible identifiers rather than secrets.
- `Viewer/NearWireViewer/Resources/Info.plist:23-28` contains the exact Bonjour declaration and local-network purpose string.
- `Viewer/NearWireViewer/Resources/NearWireViewer.entitlements:5-8` contains only App Sandbox and incoming network-server entitlement keys.
- `Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy:5-21` declares linked Device ID for App functionality, tracking false, and no tracking domains or Required Reason API entries. This matches the documented `vid` and Viewer Hello behavior for this change.
- Production identity load and reset work are dispatched away from the MainActor at `Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:134-151` and `Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:176-193`. The Security framework main-thread diagnostics observed in synchronous certificate unit tests do not establish a production main-thread defect.
- Documentation accurately preserves this change's boundary: no Event transfer, history, search, export, charts, or active multi-device session manager is claimed yet.

## Validation Performed

All commands were run from the repository root on 2026-07-12.

1. `xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination platform=macOS,arch=arm64 -derivedDataPath /tmp/nearwire-viewer-review-dd -clonedSourcePackagesDirPath /tmp/nearwire-viewer-review-spm test CODE_SIGN_IDENTITY=- ONLY_ACTIVE_ARCH=YES ARCHS=arm64`
   - Result: exit 0, `** TEST SUCCEEDED **`.
   - XCTest executed 34 tests: 32 passed, 0 failed, 2 skipped.
   - Skips reproduced at `ViewerFoundationTests.swift:482` (persistent `SecIdentity`) and `ViewerFoundationTests.swift:577` (isolated certificate fixture).
2. `swift test --filter SecureTransportTests`
   - Initial restricted run could not start because nested `sandbox-exec` and default cache access were denied.
   - Repeated with writable temporary module caches outside the nested sandbox: exit 0; 16 tests passed, 0 failed.
3. `DO_NOT_TRACK=1 openspec validate viewer-application-foundation --strict --no-interactive`
   - Result: exit 0; change is valid.
4. `plutil -lint Viewer/NearWireViewer/Resources/Info.plist Viewer/NearWireViewer/Resources/NearWireViewer.entitlements Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy`
   - Result: exit 0; all three files are valid.
5. `./Scripts/verify-english.sh`
   - Result: exit 0; CJK character scan passed.
6. `git diff --check`
   - Result: exit 0.

## Completion Gate

Round 1 security/performance/documentation approval is withheld. Resolve all three findings, add the required application-edge and signed-identity evidence, rerun affected and canonical validation, and request a fresh independent round. A later review should not inherit approval from this report.
