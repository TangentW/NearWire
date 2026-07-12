# SDK Public Connect Implementation Review — Round 2 Security, Performance, and Documentation

## Scope

This review re-examined the stable current worktree, active specifications and tasks, Round 1 report, and newly added evidence. It focused on Round 1 remediation, terminal fail-closed ownership, Keychain behavior, pairing retention, exact resource bounds, TLS and Viewer-authentication claims, package linkage, English documentation, and the release evidence gate. No production, test, specification, task, or existing evidence file was modified.

## Result

**Unresolved actionable finding count: 4.**

No new production security or resource-bound defect was found. The Round 1 production fixes are directionally correct: terminal-wait failure now vaults the lease, pairing ownership moves through narrow one-shot transfer objects, the Event maximum uses a direction-valid App/Viewer shape, Keychain tests cover complete live dictionaries, and the lease documentation contradiction was corrected. Four evidence or documentation findings remain: three Medium and one Low.

## Findings

### 1. Medium — The terminal-wait failure test does not prove fail-closed behavior with the real process lease

**Evidence**

- `SDK/Sources/NearWire/Connection/SDKPublicConnectionOrchestration.swift:177-207` correctly routes a throwing wait through `failClosed()` and transfers the retained lease into `SDKPublicFailClosedLeaseVault`.
- `SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:181-199` injects a wait failure, but constructs `SDKPublicConnectionLease` with a release-count closure. It proves zero callback releases and one additional vault entry, not continued contention in `ProcessConnectionLeaseRegistry`.
- `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:4051-4087` proves a real competing claim fails during an ordinary live session, and `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:4139-4142` proves reacquisition after an ordinary observed terminal. Neither path exercises terminal-observation failure.
- `openspec/changes/sdk-public-connect/reviews/implementation-round-1-security-performance-documentation.md:28-30` requested a deterministic wait-failure test that proves a competing process lease remains contended.
- `openspec/changes/sdk-public-connect/evidence/requirement-to-evidence.md:15` cites “public real-lease contention/reacquisition” for terminal fail-closed cleanup, but the real-lease integration covers only the successful terminal-observation regime.

**Impact**

The implementation is structurally fail-closed, but the security evidence does not exercise the composition of the coordinator vault, `SDKPublicConnectionLease(handle:)`, and the Objective-C process registry in the exact failure regime being protected. A future wrapper or vault regression could pass the synthetic callback test while making a real competing connection claimable.

**Recommended fix**

Add an isolated subprocess test so permanently vaulting the real lease does not poison the main test process. In that subprocess, claim through `ProcessConnectionLeaseRegistry`, wrap the handle, inject a throwing coordinator wait, wait for vault transfer, drop all ordinary owners, and assert a second registry claim returns `anotherConnectionIsActive`. Record the command and exact subprocess result in the terminal-ownership evidence.

### 2. Medium — Pairing-code retention remediation has no task-required retention test

**Evidence**

- `SDK/Sources/NearWire/Connection/SDKPublicConnectionOrchestration.swift:26-44` introduces the one-shot `SDKPairingCodeTransfer` and clears its stored value during `take()`.
- `SDK/Sources/NearWire/NearWire.swift:682-700` consumes the public transfer in a synchronous helper before the next suspension.
- `SDK/Sources/NearWire/Session/SDKSessionAdmission.swift:253-257` similarly consumes and clears the admission transfer while constructing discovery.
- `openspec/changes/sdk-public-connect/tasks.md:23-24` explicitly requires retention tests proving that no coordinator, Task, core, live operation, channel, or callback retains pairing data.
- `openspec/changes/sdk-public-connect/evidence/requirement-to-evidence.md:9` and `openspec/changes/sdk-public-connect/evidence/terminal-ownership-and-retain-graph-audit.md:23-29` rely on source/retain-graph prose and cancellation-stage tests. No test references `SDKPairingCodeTransfer`, observes one-shot clearing, or detects a retained pairing-storage probe after either transfer boundary.

**Impact**

The narrowed source scopes address the Round 1 implementation concern, but the active task promises executable retention evidence. Without it, a later change could retain the transfer or its value in an async closure while the current cancellation/state tests continue to pass. This is retention minimization for public discovery metadata, not a password-exposure or Viewer-authentication failure.

**Recommended fix**

Add deterministic tests for both transfer boundaries. At minimum, prove each transfer returns a value once and is empty immediately afterward, and use an instrumented internal storage/retention probe to show the public attempt and admission actor release their normalized-code ownership before the next suspension. Repeat the probe through cancellation and terminal paths, then cite the named tests in the retain-graph evidence.

### 3. Medium — The modified aggregate package gate has not been rerun and the saved results are not exact reproducible artifacts

**Evidence**

- `Scripts/verify-package.sh:588-610` now makes the supported public-connect production TLS test a mandatory, non-skipped package gate.
- `openspec/changes/sdk-public-connect/evidence/validation-gates.md:18` states that `verify-package.sh` passed before that new sub-gate was added.
- `openspec/changes/sdk-public-connect/evidence/validation-gates.md:34` explicitly says the final validation refresh still must rerun the modified script.
- `openspec/changes/sdk-public-connect/evidence/validation-gates.md:7-10` records summarized invocations; the production TLS entry contains an ellipsis rather than the exact command, environment, cache paths, and output required for reproduction.
- `openspec/changes/sdk-public-connect/tasks.md:8-35` still leaves all implementation, validation, evidence, review, and archive items unchecked, including tasks 4.4 and 4.5 requiring the full validation matrix and exact captured results.

**Impact**

The current source snapshot has not passed its own final aggregate packaging command, so the SwiftPM build, public API boundary checks, strict concurrency suite, real TLS admission, and newly mandatory supported-connect TLS gate have not been demonstrated together. Summary prose is useful, but it is not the repository-required exact result artifact and cannot establish that the current post-remediation worktree produced the reported output.

**Recommended fix**

After all Round 2 remediation, rerun the modified `verify-package.sh` and every affected focused/full/static/CocoaPods/OpenSpec gate on the final worktree. Save full commands, relevant environment/tool versions, exit status, test counts/skips, and untruncated output or log paths under `evidence`; remove the explicit pending-refresh statement. Then mark tasks sequentially only after each stated evidence item exists.

### 4. Low — Lower-layer documentation still uses stale future-change wording for already composed behavior

**Evidence**

- `Documentation/SDK-Discovery.md:5` correctly says public `connect(code:)` now uses the discovery layer.
- `Documentation/SDK-Discovery.md:67` says TLS establishment, Viewer admission, and Event delivery “belong to later narrow changes,” although public connect already composes the implemented admission and active-pump layers.
- `Documentation/SDK-Connection-Lease.md:24` still refers to “Future terminal connection paths” even though the current public coordinator is now that terminal path.
- `Documentation/SDK-Session-Admission.md:9` and `Documentation/Implementation-Roadmap.md:51-57` correctly describe public connect as implemented, making the historical wording inconsistent with the current boundary.

**Impact**

The security claims themselves remain accurate, but maintainers can misread implemented TLS/admission/terminal ownership as still pending. This weakens the documentation audit and makes residual lifecycle scope less precise.

**Recommended fix**

Replace historical “later/future change” wording with layer ownership: discovery does not itself establish TLS or transfer Events, while the current public coordinator composes admission and the active pump; future work is limited to disconnect, reconnection, and lifecycle policy. Update the lease text to refer to the current terminal coordinator, then rerun the English terminology audit.

## Confirmed Round 1 Remediation and Positive Observations

- Terminal-wait execution failure explicitly removes the coordinator lease and permanently vaults it before the Task ends; ordinary terminal delivery releases exactly once.
- The process lease handle now has its own lock-protected one-shot release boundary, preserving fail-closed behavior for failed runtime synchronization and preventing repeated runtime release calls.
- The exact Event-record formula now uses one App and one Viewer role, an equality test reaches the 262,144-byte content bound, seeded/adversarial shapes remain below it, and downstream capacities are asserted against reviewed defaults and hard maxima.
- Keychain read/add dictionaries remain least-privilege. Tests compare full dictionaries and bridge all abstract attributes to actual `Security.framework` constants. Identity generation, duplicate reread, malformed values, inaccessible values, and failure transcripts remain bounded and content-safe.
- Public connection errors remain fixed and content-free. No pairing, endpoint, certificate, metadata, Event, Security query, OSStatus, or underlying network description is forwarded.
- TLS documentation continues to state mandatory TLS 1.3 while accurately disclaiming pre-established Viewer authentication and active-attacker protection under connection-local leaf anchoring.
- SwiftPM and CocoaPods attach `Security.framework` to the SDK target/subspec without exposing Security types or adding third-party runtime dependencies.

