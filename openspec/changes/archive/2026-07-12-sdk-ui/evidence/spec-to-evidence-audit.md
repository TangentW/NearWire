# Spec-to-Evidence Audit

Date: 2026-07-12

## `sdk-ui` Delta

| Added requirement | Evidence status |
| --- | --- |
| One injected connection panel and one value-driven status view | Implemented; exact public schema and both distribution consumer fixtures pass |
| Construction and presentation preserve host lifecycle ownership | Implemented; construction, observation-count, teardown, deinit, and connected-disappearance tests pass |
| Pairing input is bounded, memory-only, and SDK-validated | Implemented; complete scalar-prefix matrix and exact forwarding/clearing tests pass |
| One internal coordinator owns exact cooperative action bounds | Implemented; deduplication, synchronous initial phase, shared panels, cancellation, fail-closed hold, reentrant cancellation, publication/termination races, both acknowledgement orders, and cleanup tests pass |
| Action availability is conservative and total over public state | Implemented; state, suspension, terminal error, ownership reset, and coordinator phase tests pass |
| Status and errors are complete, safe, and accessible | Implemented; closed presentation tests, unknown-error sanitization, error winner, fixed-English source audit, and accessibility-size rendering pass |
| NearWireUI remains optional and resource-safe | Implemented; source/resource audit, product/subspec boundaries, strict minimum-platform builds, consumers, and aggregate API checks pass |
| Injected-instance replacement resets state ownership | Implemented; identity-key source gate plus distinct-controller replacement, generation, stopped-status, and predecessor-completion tests pass |

## `sdk-public-boundary` Delta

| Modified requirement | Evidence status |
| --- | --- |
| SDK modules expose only supported facade types | SwiftPM and CocoaPods external consumers pass; internal-name fixtures fail for the expected declaration; SDK-only CocoaPods cannot name UI; UI aggregate retains SDK API and adds exactly the approved view declarations, initializers, bodies, and source-declared `View` conformance while normalizing toolchain-synthesized markers |

## Gate Audit

- Proposal, design, specs, and tasks validated before source apply: complete.
- Five independent pre-implementation review rounds ended with zero findings: complete.
- Focused strict-concurrency tests: 43 passed, zero failed; final 25-suite stress run: 1,075 passed; reverse-delivery race: 100 consecutive passes.
- Full macOS strict-concurrency suite: 470 executed, seven existing environment-gated skips, zero failed.
- Full iOS simulator suite: 470 total, 466 passed, four existing skips, zero failed.
- Core harness: 196 passed; TLS admission and real bidirectional public-connect integrations: one passed each.
- SwiftPM/CocoaPods external consumers, exact public schema, minimum-platform builds, source/resource audits, and package gate: passed.
- `pod lib lint` and repository podspec gate: passed with only expected pre-release metadata warnings/notes.
- Implementation review and fresh zero-finding review round: complete; Round 6 architecture/API, correctness/testing, and security/performance/documentation reports each record zero actionable findings.
- Archive and archived-evidence verification: complete; `sdk-ui` was archived as `2026-07-12-sdk-ui`, the main `sdk-ui` and modified `sdk-public-boundary` specifications pass strict validation, and all required evidence files are present in the archive.

Every requirement is closed with implementation, validation, independent zero-finding review, and archived evidence.
