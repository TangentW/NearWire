# Pre-Implementation Security, Performance, and Documentation Review — Round 2

## Scope

Independently re-reviewed the complete current `viewer-application-foundation` proposal, design, capability specifications, tasks, the Round 1 security/performance/documentation report, relevant existing Core listener/channel and trust implementation, and current Apple primary guidance. This round specifically retraced the three Round 1 findings through normative requirements and planned evidence. No proposal, design, specification, task, production, test, or evidence artifact was modified; this report is the only added file.

## Findings

No unresolved security, performance, privacy, entitlement, or documentation finding was identified.

## Round 1 Finding Resolution

### Runtime-wide pre-session resource bound — resolved

The capacity now begins at the correct boundary. One exact 32-slot budget is shared by current and replacement listeners; a slot is reserved before wrapper claim or any channel, decoder, deadline Task, or UI work (`design.md:63-77`; `specs/viewer-application-foundation/spec.md:95-103`). It remains owned across TLS readiness, silent or partial Hello input, automatic or confirmation policy, and consumer handoff. A 33rd connection is cancelled before per-connection work, so listener bursts cannot create an unbounded actor/Task backlog ahead of admission.

Every claimed attempt uses one non-resetting monotonic 10-second claim-to-handoff/cancel deadline. That applies to both policies and stays inside the App SDK's existing 15-second total secure-admission budget. The transition table defines policy changes, pause, replacement preparation/commit/failure, shutdown, deadlines, Accept, Reject, and handed-off ownership (`design.md:75-83`). Every terminal path claims one outcome and releases the exact slot once.

Task 4.3 and task 5.1 require the same permanent connection core, 32/33 boundary, silent/partial peers under both policies, shared-generation accounting, one deadline, continuous decoder ownership, and exact cleanup counters (`tasks.md:22,26`). This closes the local socket/channel/Task exhaustion gap without adding a queue or session manager.

### X.509, Keychain, repair, and reset lifecycle — resolved

The self-signed certificate is now one fixed, non-identifying X.509 v3 profile: P-256 SPKI, ECDSA-with-SHA256, bounded positive random serial, fixed subject/issuer, five-minute not-before skew, 3,650-day validity, CA=false, digital-signature and server-auth use, and no SAN or network-fetching extension (`design.md:39-45`; `specs/viewer-application-foundation/spec.md:21-27`). Load verifies the exact profile, self-signature, private/public correspondence, leaf-only Basic X.509 trust, current validity, and at least 30 days remaining. Expired, not-yet-valid, near-expiry, mismatched, or partial identity receives one stop-before-repair renewal attempt and otherwise fails closed. This is a clear, testable expiry exception to ordinary identity stability.

Keychain ownership is also exact. The plan uses the macOS data-protection Keychain, synchronization false, no shared access group, exact generic-password service/accounts, one exact application-tagged permanent/sensitive/nonextractable P-256 private key, and certificate selection through a metadata-owned persistent reference cross-checked by serial and public-key hash (`design.md:47-49`). Missing metadata cannot authorize a broad certificate deletion, and fallback deletion requires all stored metadata plus owned-key correspondence.

TLS-only reset and confirmed full identity reset have separate scopes. Both close listener/admission first; TLS reset deletes only the exact certificate reference, private-key tag, and TLS metadata while preserving installation ID; full reset additionally deletes the exact installation account. Partial deletion or recreation stays failed closed, foreign items are preserved, and app removal is no longer claimed to clear Keychain state (`design.md:49,108-110`). Tasks require nonexportability, foreign-item preservation, validity boundaries, renewal, partial deletion, both reset scopes, real Security trust, and reset interruption coverage.

The private DER encoder remains proportionate. Its accepted profile is closed, real Security parses and evaluates its certificate, a live TLS path remains part of implementation evidence, and no general ASN.1 framework or third-party dependency is introduced.

### App metadata, privacy, and Bonjour disclosure — resolved

The build contract now enables App Sandbox with only `com.apple.security.network.server`; it excludes client, multicast, Keychain-sharing, app-group, and background-service entitlements. Development/test builds use the committed entitlement file with inspectable local signing (`design.md:112-118`; `specs/viewer-application-foundation/spec.md:179-189`). Server-accepted TCP remains bidirectional, so no client entitlement is needed for this foundation.

The built Info.plist must contain `_nearwire._tcp` in `NSBonjourServices` and the exact bounded English `NSLocalNetworkUsageDescription`. Local-network denial is a fixed recoverable failure with no alternate or plaintext transport. The Viewer owns a separate `PrivacyInfo.xcprivacy` declaring linked Device ID for App functionality and tracking false, while omitting tracking domains and unused Required Reason categories. This matches its stable `vid` publication and full installation ID in Viewer Hello.

The UI must now state positively that both the pairing code and stable `vid` are visible to nearby Bonjour browsers and are not secrets (`design.md:85-95`; `specs/viewer-application-foundation/spec.md:162-166`). The separate wording `TLS encrypted; Viewer identity is not authenticated` remains precise and prevents discovery metadata, the public code, or a self-signed leaf from being presented as authenticated identity.

Tasks 2.1, 2.3, 5.3, and 5.4 cover the entitlement, Info.plist, privacy resource, disclosure, denial/recovery documentation, built-product inspection, and signing evidence. Distribution signing and notarization can remain later work; local signing here is only the proportionate mechanism needed to build and inspect the sandboxed test product.

## Additional Security and Performance Verification

- Pairing generation remains unbiased, memory-only, bounded to one code per listener generation, and absent from Keychain, logs, analytics, errors, and session data except explicit user clipboard action.
- Bonjour still publishes only the exact instance and one validated `vid`; ready plus exact registration is required before UI usability, and conflict-renamed registrations cannot masquerade as the displayed code.
- One permanent admission connection core owns callbacks and its continuous bounded decoder from channel construction through opaque handoff. Approval transfers only one consumer right, preventing raw-byte loss, handler replacement, or duplicate terminal ownership.
- Pause cancels every claimed/pre-Hello and pending attempt while preserving handed-off ownership. Refresh keeps the old registered listener usable until replacement commit and shares the same capacity, avoiding both downtime on failed replacement and multiplied resource limits.
- Window ownership, generation tokens, stale-callback rejection, last-window termination, and no menu-bar/daemon behavior bound idle lifetime. The placeholder consumer closes accepted handoffs, so active-session counts properly remain deferred to `viewer-multidevice-flow-control`.
- The change remains narrowly scoped: no backend, database, event pump, flow-policy engine, general certificate authority, project generator, or third-party runtime dependency is introduced.

## Reviewer Validation

- `DO_NOT_TRACK=1 openspec validate viewer-application-foundation --strict --no-interactive`: **PASS**.
- `./Scripts/verify-english.sh`: **PASS**, with the expected human semantic-review note.
- `git diff --check -- openspec/changes/viewer-application-foundation`: **PASS**.
- Proposal, design, capability scenarios, tasks, and planned evidence now agree on all three remediated boundaries.

## Verdict

**Pre-implementation security/performance/documentation approval granted. Exact unresolved actionable finding count: 0.**
