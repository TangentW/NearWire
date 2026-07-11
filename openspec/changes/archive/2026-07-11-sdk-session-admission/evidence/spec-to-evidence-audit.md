# Spec-to-Evidence Audit

## Session Admission Capability

| Requirement and scenarios | Evidence | Result |
| --- | --- | --- |
| One explicit internal operation; run ordering; idle construction; exact local revalidation | `testLocalRoleAndOutboundCapacityFailBeforeDiscovery`, `testCancelBeforeRunAndSecondRunAreDeterministic`, `testGenuineSecondRunReturnsAlreadyStarted`, production composition test, structure audit | Covered |
| Bounded fail-closed state machine; exact success; rejection; approval ping | happy-path, rejection/early-Event, awaiting-approval, malformed-control, incompatibility, terminal-priority, and real-TLS tests | Covered |
| Discovery and hello identity agree; mismatch and non-authentication limits | `testViewerIdentityMismatchFailsAndCancelsChannel`, happy-path and real-TLS tests, `Documentation/SDK-Session-Admission.md` | Covered |
| Strictly bounded input and streaming state; fragmented/coalesced input; early Event; callback storm | happy-path, ingress bounds, ingress overflow, ingress quantum, cumulative work, and Core lane-preflight tests | Covered |
| Stage deadlines and exact cleanup; discovery race; cancellation/acknowledgement race | deadline matrix, task cancellation matrix, transfer barrier, stale-token/overflow test, handle-ownership tests | Covered |
| Continuous admitted owner; coalesced policy; terminal suffix; attachment races; handle release; pull races and precedence; ping storm; redaction | happy-path, terminal suffix, pull gate, policy-pull matrix, unique-token ABA matrix, handle ownership, actor release, handoff limits, redaction matrix | Covered |
| Closed and safe errors; hostile underlying text; terminal attachment; second attachment | exhaustive error/redaction test, discovery-category matrix, rejection/malformed and acknowledgement matrices, attachment/ownership tests | Covered |
| No later ownership or Event features | structure audit, public-boundary negative consumers, `testAdmissionDoesNotClaimLeaseOrMutateNearWireFacadeState`, API/residual audit | Covered |

## Modified Capabilities

| Capability | Evidence | Result |
| --- | --- | --- |
| Wire framing lane preflight: byte fragmentation, coalescing, terminal reuse, rejection before payload | ten `WireFrameTests`, including exact-once preflight, no-payload retention, private-error normalization, and terminal reuse | Covered |
| SDK public boundary remains source-compatible and side-effect-free | SwiftPM and CocoaPods consumer compilation, ABI dump boundary, forbidden implementation-type fixture, unchanged manifests and supported facade files | Covered |
| Bonjour matching remains non-authenticating and hello discriminator mismatch fails | identity mismatch test, production TLS test, English admission documentation, security Round 3 review | Covered |

## Gate Audit

- Every task has corresponding source, test, documentation, review, or raw validation evidence.
- The canonical evidence capture is complete, belongs to one run ID, and records exit status 0 for all nine gates.
- Focused admission coverage executed all 29 tests with no skip or failure.
- The dedicated real-TLS package gate executed exactly one test with no skip or failure.
- Round 3 independent reviews have no unresolved finding.
- `git diff --check`, Swift formatting, structure, language, version, validation-tool, boundary, SwiftPM, CocoaPods, and strict OpenSpec checks all pass.
- Residual work begins at `sdk-active-event-pump`; this change does not implement it.

Conclusion: every changed requirement and scenario has proportionate evidence, no task is supported only by a narrower unrelated test, and no unresolved finding remains.
