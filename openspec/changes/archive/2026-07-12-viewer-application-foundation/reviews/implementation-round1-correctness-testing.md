# Implementation Correctness and Testing Review — Round 1

Date: 2026-07-12

## Scope

Independently reviewed the complete active `viewer-application-foundation` artifacts and checked tasks, the current worktree diff, Viewer and changed Core production code, the manual Xcode project and scheme, all Viewer tests, changed Core/SDK tests, documentation, and implementation-validation evidence. The review focused on state-machine correctness, concurrency and generation races, admission bounds and terminal ownership, Keychain repair/reset safety, certificate construction and validation, deterministic coverage, packaging, and requirement-to-evidence traceability. No production, specification, task, test, or evidence file was modified.

## Findings

### 1. P1 / High — Explicit TLS reset can accept a partial identity and delete a certificate without proving ownership

**Confidence: 10/10**

The normative identity contract requires certificate selection to be cross-checked by serial and public-key hash, foreign items to be preserved, and partial deletion to fail closed (`specs/viewer-application-foundation/spec.md:21-27,51-54`). `TLSMetadata` stores the persistent reference, label, serial, public-key hash, and certificate hash (`Viewer/NearWireViewer/Identity/ViewerIdentityStore.swift:49-56`), but the reset path validates only certificate hash and serial before deleting the referenced certificate (`ViewerIdentityStore.swift:246-266`). It does not load the exact private key, prove certificate/key correspondence, compare `publicKeyHash`, or verify the stored label before the destructive operation. It then treats a missing private key as successful deletion because `deletePrivateKey()` delegates to a helper that accepts `errSecItemNotFound` (`ViewerIdentityStore.swift:272-273,345-346,440-443`).

Consequently, metadata plus certificate with a missing owned key—a partial identity that the spec says must fail closed—causes `resetTLSIdentity()` to delete the certificate and report success. More seriously, corrupted metadata that consistently references an unrelated certificate and supplies that certificate's hash and serial can make the reset delete that foreign certificate even though no matching owned private key exists. The current foreign-item test covers only the much easier no-metadata case and was skipped on the validation host (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:557-599`).

**Required resolution:** before deleting anything, resolve and validate the complete owned tuple: exact metadata selector/version, persistent certificate reference, stored label/serial/certificate hash/public-key hash, exact tagged private key, certificate/key correspondence, and expected key attributes. Explicit reset must fail without deleting the certificate when any required owned item is missing or mismatched. Add destructive-path tests for missing key, wrong key, metadata referencing a foreign certificate, mismatched public-key hash, certificate-delete failure, key-delete failure, and metadata-delete failure, asserting both returned state and every surviving Keychain item.

### 2. P2 / Medium — The production data-protection Keychain lifecycle has no passing transition evidence

**Confidence: 10/10**

Tasks 3.1 and 5.1 are marked complete for data-protection Keychain transitions, stable reload, repair, renewal, foreign-item preservation, nonexportability, partial deletion, and both reset scopes (`tasks.md:14,26`). The only lifecycle integration test uses `ViewerKeychainNames.isolated()`, which explicitly disables the data-protection Keychain (`ViewerIdentityStore.swift:33-38`), and that test skips before any reuse/reset assertion when `SecIdentity` assembly fails (`ViewerFoundationTests.swift:473-508`). The foreign-certificate preservation test also skips (`ViewerFoundationTests.swift:557-599`). The independent review run reproduced exactly 34 tests with 2 skips. The evidence acknowledges both skips (`evidence/implementation-validation.md:40-55`) but still treats the checked task and implementation gate as complete.

The remaining passing tests assert only that the live configuration Boolean is true and that malformed metadata is preserved during explicit reset (`ViewerFoundationTests.swift:510-555`). They do not execute the production data-protection query shape or prove automatic one-attempt repair, near-expiry store renewal, partial create cleanup, partial delete behavior, stable `SecIdentity` reuse, or the actual reset scopes. A successful build and certificate-builder unit tests cannot substitute for those state transitions.

**Required resolution:** introduce an injectable Keychain/Security storage boundary and deterministic state-machine tests for every load/create/repair/reset transition and every operation failure, including exact call counts and preserved foreign records. Also run at least one supported signed integration configuration against `kSecUseDataProtectionKeychain=true` that creates, reloads, adapts, resets, and recreates a real identity. A skipped test must remain an explicit environment limitation, not evidence for checking these requirements complete.

### 3. P2 / Medium — Admission and listener race tests are wall-clock tests, not the deterministic terminal-race coverage claimed by task 5.1

**Confidence: 10/10**

`ViewerAdmissionManager` injects only a duration; it reads `DispatchTime.now()` directly and starts a real `Task.sleep` (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:354-369`). The deadline tests wait 250 or 500 milliseconds of wall time (`ViewerFoundationTests.swift:780-864`), while listener-generation tests repeatedly sleep arbitrary 20–100 millisecond intervals before assertions (`ViewerFoundationTests.swift:63-65,85-98,118-131,152-177,198-234`). The validation evidence even says the full suite was rerun after “deadline-test stabilization” (`evidence/implementation-validation.md:48`).

These tests cover eventual timeout, but they do not deterministically order Accept/Reject against timeout, Pause against timeout/Hello, replacement commit against Hello/timeout, shutdown against handoff, or a channel terminal event against each policy action. They therefore do not prove the one terminal outcome and one slot release required by the spec (`spec.md:99-103`) and the checked deterministic-race task (`tasks.md:22,26`). Passing twice does not make scheduling-dependent tests deterministic.

**Required resolution:** inject a monotonic clock/deadline scheduler and explicit race barriers. Advance a test clock rather than sleeping, run both winner orderings for every terminal transition, and assert exactly one consumer handoff or channel cancellation, exactly one slot release, no stale pending row, and no post-terminal callback effect. Replace application-model sleeps with event/continuation-driven synchronization so listener generation tests fail only on behavior, not scheduler latency.

### 4. P2 / Medium — Window shutdown requests asynchronous cancellation but provides no bounded cleanup opportunity

**Confidence: 9/10**

The specification requires last-window/application shutdown to finish bounded cleanup (`spec.md:7`), and the design explicitly gives owned connection attempts a short bounded opportunity to finish (`design.md:35-37`). `ViewerApplicationModel.stopRuntime()` calls `admissionManager.stop()`, cancels listeners, immediately clears state, and publishes `.stopped` without awaiting any completion (`Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:160-174`). Manager cleanup calls `core.cancel()` (`ViewerAdmission.swift:413-423,487-500`), but core cancellation merely enqueues work on its serial queue and launches another asynchronous Task for `channel.cancel()` (`ViewerAdmission.swift:165-170`). The app delegate then permits immediate termination after the last window closes (`Viewer/NearWireViewer/App/NearWireViewerApp.swift:13-19,34-37`).

There is no completion barrier, bounded wait, or termination deferral, so a busy core queue or delayed channel cancellation may receive no cleanup opportunity before process exit. The application-model shutdown test checks only immediate presentation state and does not observe admission/channel cleanup (`ViewerFoundationTests.swift:38-73`). Process exit ultimately tears down sockets, but that is not the specified bounded, owned cleanup protocol and cannot support future handed-off consumer shutdown reliably.

**Required resolution:** make runtime stop expose a completion signal for listener/admission/consumer cleanup and coordinate last-window/application termination with a small explicit upper bound. Test immediate completion, stalled cleanup reaching the bound, repeated stop, 32 occupied attempts, handed-off consumer closure, and late callbacks after completion.

### 5. P2 / Medium — The fixed 3,650-day certificate profile cannot be issued after early 2040

**Confidence: 10/10**

The builder always sets `notAfter` to creation plus 3,650 days (`Viewer/NearWireViewer/Identity/ViewerCertificateBuilder.swift:35-37,100-107`), but its only time encoder rejects any year outside 1950–2049 and emits only ASN.1 `UTCTime` (`ViewerCertificateBuilder.swift:377-386`). The fixed-profile parser likewise accepts only `UTCTime` (`ViewerCertificateBuilder.swift:389-402`). Once a creation date in early 2040 produces a `notAfter` in 2050, normal identity creation or renewal fails with `encodingFailed`, permanently preventing listener startup even though X.509 represents 2050 and later with `GeneralizedTime`.

The claimed boundary coverage uses a single creation epoch around 2027 and tests validity-window comparisons, not the 2049/2050 encoding transition (`ViewerFoundationTests.swift:332-421`).

**Required resolution:** encode and parse canonical `GeneralizedTime` for dates in 2050 or later while retaining `UTCTime` for 1950–2049, then add fixed fixtures immediately before and after the transition plus a post-2040 build/validate/renewal test through Security.

## Verified Strengths

- Admission reserves the shared budget before production wrapper claim, rejects the 33rd attempt before channel creation, retains one connection core and decoder, and uses lock-protected dictionary removal as a practical one-winner terminal gate (`ViewerAdmission.swift:327-384,427-500`).
- Pause and generation cancellation remove attempts under the same manager lock, and the application commits a replacement only after both ready and exact registration while preserving the old listener on preparation failure (`ViewerApplicationModel.swift:246-345`).
- The listener's admission gate preserves cancel-versus-claim atomicity, and unclaimed production wrappers cancel their underlying `NWConnection` on deinitialization (`Core/Sources/NearWireTransport/SecureByteChannel.swift:798-811,882-965`).
- The manual project, root workspace linkage, Swift 5/macOS 13 settings, sandbox resources, privacy manifest, and local package linkage build successfully. The independent Viewer test command completed with 32 passes, 2 skips, and 0 failures.

## Independent Validation

- `xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-review-round1-dd -clonedSourcePackagesDirPath /tmp/nearwire-review-round1-spm test CODE_SIGN_IDENTITY=- ONLY_ACTIVE_ARCH=YES ARCHS=arm64`: **PASS with 2 skips** (34 executed, 32 passed, 2 skipped).
- The two skipped tests are the identity lifecycle/reset integration and foreign-certificate preservation test described in Finding 2.

## Verdict

**Changes required. Exact unresolved actionable finding count: 5 — 1 High and 4 Medium.**
