# Core Event Model Review: Round 5

## Result

- Architecture and API: one task-state finding; implementation and evidence otherwise ready.
- Correctness and testing: two missing evidence fixtures.
- Security, performance, and documentation: zero findings and ready to archive.

## Findings and resolutions

### 1. Task 6.4 remained unchecked — P2

The task correctly remained open while final audit findings were being addressed. It will be marked complete only after the corrected canonical evidence and fresh review are finished.

### 2. Draft Codable helper lacked direct round-trip coverage — P2

A new regression encodes and decodes an `EventDraft` with compact floating-point content, high priority, a two-day custom TTL, correlation, and reply-to metadata. It proves acceptance with the permissive limit set and rejection with defaults.

### 3. Required performance header omissions lacked fixtures — P2

A new table-driven test removes `schemaVersion`, `sampledAt`, and `sampleIntervalMilliseconds` one at a time from valid content and proves each typed decode fails without producing a snapshot.

## Corrected evidence

Canonical run `20260710T222748Z-85587` was captured after both regression tests. It reports iOS 37/37, macOS Core harness 34/34, and NearWireCore 31/31 with all nine gates exiting 0. A final fresh archive-readiness review remains required.
