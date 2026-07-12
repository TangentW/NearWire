# SDK Public Connect Implementation Review — Round 3 Security, Performance, and Documentation

## Scope

This review examined the final-remediation worktree against the active specifications, task plan, Round 1 and Round 2 findings, and current evidence. It specifically revalidated real process-lease behavior after terminal-wait failure, pairing-code retention, final SwiftPM and CocoaPods evidence, documentation terminology, deterministic resource bounds, Keychain least privilege, safe errors, and TLS threat-model claims. No production, test, specification, task, or existing evidence file was modified.

## Result

**Unresolved actionable finding count: 2.**

Both findings are Low severity and concern documentation/evidence provenance. No unresolved implementation, Keychain, TLS, privacy, error-leakage, lease-safety, packaging-linkage, or resource-bound defect was found.

## Findings

### 1. Low — Discovery documentation still calls current downstream owners “future” or “later” layers

**Evidence**

- `Documentation/SDK-Discovery.md:5` correctly says public `connect(code:)` uses the discovery layer.
- `Documentation/SDK-Discovery.md:7` still says the browser is started by its “future session owner,” although the current public coordinator is that owner.
- `Documentation/SDK-Discovery.md:48` refers to “later TLS and protocol-admission layers,” while the same document now correctly states at line 67 that public connect composes discovery with the current TLS admission and active Event pump.
- `Documentation/SDK-Connection-Lease.md:24` and `Documentation/SDK-Discovery.md:67` show that the other stale future-change wording identified in Round 2 was corrected.

**Impact**

The authentication and encryption statements remain accurate, but these two historical adjectives make implemented ownership sound pending and prevent the terminology remediation from being complete.

**Recommended fix**

Change line 7 to “current public session owner” or simply “session owner.” Change line 48 to “downstream TLS and protocol-admission layers” or “the current TLS and protocol-admission layers.” Rerun the English terminology audit after the edit.

### 2. Low — Final validation summaries are fresh, but run identity and raw-result provenance remain incomplete

**Evidence**

- `openspec/changes/sdk-public-connect/evidence/validation-gates.md:7-19` now records exact focused commands and fresh final counts: 405 strict tests, final `verify-package.sh`, final `verify-podspec.sh`, and both production TLS gates.
- `openspec/changes/sdk-public-connect/evidence/validation-gates.md:21-34` records the static gate names and confirms that aggregate distribution gates were rerun after Round 2 remediation.
- `openspec/changes/sdk-public-connect/evidence/run-identity.md:3-6` still records only the baseline branch/commit, the earlier generic evidence-refresh value, and a toolchain contract. It does not record the actual Xcode, Swift, or CocoaPods versions used for the final run.
- The active `evidence` directory contains only summarized Markdown files; it does not identify preserved command-output logs, their hashes, or another exact raw-result artifact for the final aggregate package and pod executions.
- `openspec/changes/sdk-public-connect/tasks.md:33-34` marks the full validation and exact evidence tasks complete, while the repository workflow requires exact saved results under the active evidence directory.

**Impact**

The reported commands and counts are credible and materially close the Round 2 aggregate-gate finding, but a later auditor cannot tie those summaries to actual final tool versions or verify untruncated aggregate output. This is an evidence provenance gap, not evidence that a build or security gate failed.

**Recommended fix**

Refresh `run-identity.md` with the final UTC timestamp and actual Xcode build, Swift compiler, CocoaPods, and OpenSpec versions. Preserve the final aggregate command outputs under `evidence/logs` (or record stable log paths plus cryptographic hashes), and link them from `validation-gates.md` with exit status and exact skip/failure counts. Then run the final spec-to-evidence audit.

## Verified Round 2 Remediation

- `SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:210-264` launches an isolated macOS xctest child, claims the real `ProcessConnectionLeaseRegistry` handle, injects terminal-wait failure, waits for vault transfer, drops the coordinator, and proves a second real claim remains contended. The child boundary safely confines the intentional process-lifetime lease.
- `SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:73-79` proves `SDKPairingCodeTransfer` is immediately empty and one-shot after synchronous transfer. `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:4149-4200` holds discovery at its first suspension in both cancellation-owner orderings and proves the admission actor no longer owns pairing data.
- `openspec/changes/sdk-public-connect/evidence/terminal-ownership-and-retain-graph-audit.md:14-29` now cites the child-process lease proof, facade runtime failure matrix, async boundary races, deinitialization proof, and pairing ownership assertions.
- `openspec/changes/sdk-public-connect/evidence/validation-gates.md:7-34` records a fresh 405-test strict run, 37 focused public-connection tests, production public-connect TLS, final package verification with the new mandatory TLS sub-gate, final CocoaPods verification, boundary/structure/English/version/format gates, and strict OpenSpec validation.

## Confirmed Security, Performance, and Packaging Properties

- Terminal-wait registration or execution failure retains the exact process lease in a permanent fail-closed vault; ordinary terminal evidence releases the one-shot handle exactly once.
- The deterministic Event maximum is exact for a direction-valid App/Viewer record, reaches the 262,144-byte content boundary through the production codec, and propagates only reviewed-default or exact-required downstream capacities within hard maxima.
- Keychain access uses exact generic-password read/add dictionaries, the data-protection Keychain, authentication-UI skip, `WhenUnlockedThisDeviceOnly`, canonical V4 UUID validation, one bounded duplicate reread, and no update/delete/log/status-forwarding path.
- Pairing data and installation identity are documented with their correct privacy semantics: the pairing code is public discovery metadata, and the installation ID is a device-local correlation identifier rather than an authentication credential.
- Public errors remain fixed and content-safe. No pairing, Bonjour, endpoint, interface, certificate, metadata, Event, OSStatus, Security query, or arbitrary underlying description is exposed.
- Supported transport remains mandatory TLS 1.3 with no plaintext downgrade. Documentation correctly limits the connection-local leaf trust model: it does not provide pre-established Viewer authentication or protection from an active local impersonator.
- SwiftPM and CocoaPods both link Apple's `Security.framework` only for the SDK target/subspec and expose no Security, Network, lease, admission, pump, or wire implementation type in supported API.

