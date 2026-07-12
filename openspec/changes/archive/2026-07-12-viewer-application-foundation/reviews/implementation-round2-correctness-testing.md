# Implementation Correctness and Testing Review — Round 2

Date: 2026-07-12

## Scope

Independently re-read the complete current `viewer-application-foundation` proposal, design, specifications, tasks, all changed production/test/project/documentation files, implementation evidence, all three Round 1 implementation reviews, and the Round 1 remediation record. This review traced every prior correctness finding through the final implementation and tests, then re-audited admission, listener-generation, cleanup, Keychain, certificate, packaging, and evidence state machines for new gaps. No production, specification, task, test, documentation, or evidence file was modified.

## Round 1 Finding Disposition

| Prior correctness finding | Round 2 disposition |
| --- | --- |
| Destructive reset did not prove complete certificate/key ownership | **Resolved.** `validateOwnedTLSMetadata` now validates metadata version/shape, certificate reference/hash/serial, exact private key, fixed profile, self-signature/trust, public-key hash, and key correspondence before certificate deletion. Missing/wrong keys and adversarial foreign references fail before delete, with passing injected and real-Keychain tests. |
| Production identity lifecycle had no passing executable evidence | **Resolved.** The approved contract now uses the standard per-user login Keychain for ad-hoc/local zero-configuration operation. The independent Viewer run executed all 44 test cases successfully, including real persistent identity creation, reload, `SecIdentity` assembly, nonexportability, both resets, malformed metadata, and foreign-certificate preservation. |
| Deadline and listener races depended on wall time | **Partially resolved.** Admission deadlines and Accept-versus-timeout use a manual monotonic scheduler, but the required complete terminal-race matrix and application-model synchronization are still incomplete; see Finding 2. |
| Shutdown/reset had no bounded cleanup receipt | **Partially resolved.** Stop now returns an idempotent one-second receipt and AppKit termination/reset awaits it, but the receipt loses cleanup already removed from the live attempt dictionary; see Finding 1. |
| Certificate issuance failed when the lifetime crossed 2050 | **Partially resolved.** Issuance and normal validation now support both time forms, but load parsing does not enforce their canonical year split; see Finding 3. |

## Findings

### 1. P2 / Medium — The stop receipt omits already-cancelling attempts and can complete before all owned channel cleanup

**Confidence: 10/10**

`ViewerAdmissionManager.stop()` snapshots only the attempts still present in `attempts`, builds its cleanup task from that array, and then waits those cores plus `closeHandedOff` (`Viewer/NearWireViewer/Admission/ViewerAdmission.swift:579-608`). Every other terminal action—Pause, generation replacement/failure, Reject, timeout, or an earlier error—first removes its attempt and calls `requestCancellation()` without registering the resulting cleanup with the manager (`ViewerAdmission.swift:555-577,643-699`). `requestCancellation()` is asynchronous, and actual `channel.cancel()` completion may remain blocked indefinitely (`ViewerAdmission.swift:254-268,317-348`).

A concrete sequence is therefore:

1. admit a channel whose `cancel()` is held behind a gate;
2. call `setPaused(true)`, `cancelGeneration`, Reject, or fire its deadline, which removes the attempt and starts cancellation;
3. call `stop()` while the cancellation gate remains closed; and
4. await the receipt.

The receipt reports `.completed` because the attempt is no longer in the stop snapshot, even though the same manager-owned core has not completed channel cancellation. The analogous hole exists for a wrapper blocked inside `makeAdmissionChannel`: stop cancels the not-yet-attached core and can complete its receipt; when claim later returns, the newly produced channel is cancelled outside that receipt (`ViewerAdmission.swift:464-545`). This defeats the normative requirement that the same cleanup owner remain responsible through completion and weakens reset/retry/termination ordering (`specs/viewer-application-foundation/spec.md:7,21-25`; `design.md:35-37`).

The new cleanup test covers only an attempt that is still live when `stop()` snapshots it (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:1173-1217`). The claim barrier test checks eventual direct cancellation but never awaits a stop receipt (`ViewerFoundationTests.swift:1088-1135`).

**Required resolution:** retain every claimed or claim-in-progress core in a manager-owned cleanup registry until `cancelAndWait()` or direct post-claim channel cancellation completes, independent of admission-terminal removal and slot release. The idempotent stop receipt must snapshot or join that registry as well as handed-off cleanup. Add gated tests for Pause→Stop, Reject→Stop, timeout→Stop, replacement→Stop, and claim-in-progress→Stop; each receipt must time out while its gate is closed and later complete exactly once after the gate opens.

### 2. P2 / Medium — Deterministic scheduling covers only Accept-versus-timeout; the required terminal and listener race matrix remains incomplete

**Confidence: 10/10**

The manual scheduler is a material improvement: silent/partial/pending deadlines and both sequential winner orders for Accept-versus-timeout no longer sleep (`ViewerFoundationTests.swift:800-982,1784-1854`). However, no equivalent winner-order tests cover Reject versus timeout, Pause versus Hello/timeout, replacement commit versus Hello/timeout, stop versus Hello/timeout, or channel termination versus policy actions. These are all named terminal competitors in the normative transition contract (`spec.md:105-109`) and task 5.1 remains checked as deterministic race coverage (`tasks.md:26`).

The application-model listener tests also still use arbitrary 20–100 ms `Task.sleep` delays before state assertions (`ViewerFoundationTests.swift:63-66,87-100,120-133,154-179,200-229,246-247,1246-1248`). On a slow or oversubscribed CI host, correct callbacks can arrive after those sleeps and fail the suite; on a scheduling change, an unintended intermediate state may be skipped. The remediation record says listener races use explicit gates where ordering matters, but only the blocked-claim test has such a barrier.

**Required resolution:** exercise both controlled winner orders for every terminal competitor using the injected scheduler and explicit callback barriers, asserting one handoff-or-cancel, one slot release, one pending-list result, and no stale effect. Replace application-model sleeps with expectations/continuations emitted by the listener factory, pairing generator, model observation, or a deterministic executor-facing seam.

### 3. P2 / Medium — Fixed-profile parsing accepts noncanonical GeneralizedTime before 2050

**Confidence: 10/10**

The encoder now correctly emits UTCTime through 2049 and GeneralizedTime from 2050 (`Viewer/NearWireViewer/Identity/ViewerCertificateBuilder.swift:386-401`). The parser selects a format solely from the DER tag, validates length and a string round trip, and returns the date without checking that tag 0x17 maps to 1950–2049 or that tag 0x18 maps to 2050 and later (`ViewerCertificateBuilder.swift:403-432`). Consequently, a correctly signed certificate using GeneralizedTime for a 2049 validity value can pass the private fixed-profile parser even though the specification requires the canonical split and strict parsing (`specs/viewer-application-foundation/spec.md:31`; `design.md:43`). GeneralizedTime values before 1950 are likewise not rejected at this layer if the interval and later trust checks happen to permit the fixture.

The transition test proves only that this builder emits a 0x17 somewhere for a 2039 issuance and a 0x18 somewhere for a 2041 issuance (`ViewerFoundationTests.swift:1442-1467`). It neither inspects the two exact validity nodes nor supplies noncanonical, re-signed fixtures to prove rejection.

**Required resolution:** after parsing, enforce 1950–2049 for UTCTime and 2050–9999 for GeneralizedTime. Add exact DER-node assertions for both `notBefore` and `notAfter`, plus signed negative fixtures using GeneralizedTime in 2049 and the wrong tag on each side of the transition.

### 4. P3 / Low — Reload validates permanence and nonexportability but not the required sensitive private-key attribute

**Confidence: 9/10**

Private-key creation requests `kSecAttrIsSensitive=true` (`Viewer/NearWireViewer/Identity/ViewerCertificateBuilder.swift:53-68`), and the specification requires the stored P-256 key to remain permanent, sensitive, and actually nonexportable with its attributes validated (`specs/viewer-application-foundation/spec.md:29`). Reload checks permanence, size, and failed external representation, but it no longer checks `kSecAttrIsSensitive` (`Viewer/NearWireViewer/Identity/ViewerIdentityStore.swift:471-492`). The real lifecycle test asserts only that external representation is nil (`ViewerFoundationTests.swift:475-513`), and the injected persistence uses ephemeral keys, so neither test closes this requirement.

**Required resolution:** validate the sensitive attribute when loading the exact tagged key, or narrow the normative contract with an authoritative platform rationale if login-Keychain Security does not expose a stable readable value. Add a real-Keychain attribute assertion and an injected invalid-attribute case at the persistence boundary.

## Verified Strengths

- Admission now registers its reservation/core before wrapper claim, checks active generation identity after claim, synchronously rejects excess/stale ingress, and prevents Pause→Resume or replacement from reviving a blocked old attempt.
- The synchronous listener edge removes the former unbounded MainActor incoming-task backlog, and pending UI delivery is latest-only coalesced.
- Destructive TLS reset now preserves foreign certificates and rejects incomplete ownership before certificate deletion; injected failure tests cover certificate, key, and metadata delete failures.
- The standard login-Keychain lifecycle is executable in the ad-hoc sandboxed test host with no skips, and the documented storage contract matches current code and entitlements.
- AppKit termination, retry, and identity reset now share an idempotent bounded receipt; Finding 1 concerns which prior cleanup work joins that receipt, not the receipt/wait mechanism itself.
- The manual project, workspace linkage, Release metadata, sandbox entitlements, privacy manifest, root package boundaries, and changed Core transport API remain coherent.

## Independent Validation

- Viewer app-hosted XCTest command equivalent to the recorded final command: **PASS**. Legacy `xcresulttool` inspection reported `testsCount=44`, action status `succeeded`, and exactly 44 `Success` test statuses with no skipped or failed status.
- Focused strict-concurrency `SecureTransportTests`: exit 0; 16 executed, 11 passed and 5 skipped because Security trust/Network services are unavailable inside this review agent's outer restricted sandbox. This environment limitation does not contradict the separately recorded unrestricted 16-pass result, but it prevents independently reproducing that integration count here.
- `DO_NOT_TRACK=1 openspec validate viewer-application-foundation --strict --no-interactive`: **PASS**.
- `git diff --check`: **PASS**.

## Verdict

**Approval withheld. Exact unresolved actionable finding count: 4 — 0 High, 3 Medium, and 1 Low.**
