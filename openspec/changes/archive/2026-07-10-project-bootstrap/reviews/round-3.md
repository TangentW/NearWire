# Review Round 3

## Reviewers

- Architecture, module boundaries, API surface, and packaging
- Correctness, tests, reproducibility, and failure handling
- Security, supply chain, performance, documentation, and OpenSpec compliance

## Consolidated Findings

### P1: Canonical evidence capture could mix runs

A failed recapture could stop before later logs and leave an older successful log in the canonical directory.

Resolution: assign a run ID, delete every owned log before capture, publish an atomic mode status, mark failed captures incomplete, verify that all canonical logs share one completed all-mode run ID, and add a forced-failure regression test.

### P2: Swift import scanning did not implement the Swift grammar

Block comments could hide a real platform import or create a false import, and a multiline `@_exported` attribute could bypass re-export detection.

Resolution: use the Swift compiler parser to inspect import declarations and exported attributes. Add comment-prefixed, comment-only, declaration-specific, attributed, and multiline re-export fixtures.

### P2: Core package test harness could drift

The Core-only macOS package fixture duplicated target metadata without a parity gate, and the explicit macOS build list was separately hard-coded.

Resolution: compare normalized target names, types, paths, and dependencies between the root package and Core fixture, add a drift regression test, and derive macOS build targets from the root package dump.

### P2: Manifest path checks permitted traversal

Lexical `Core/` or `SDK/` prefixes allowed paths containing `..` to resolve into Viewer or another unauthorized root.

Resolution: reject absolute paths and parent traversal before normalized containment checks for SwiftPM and CocoaPods, with negative fixtures for each manifest.

### P2: Bootstrap pod metadata was unsafe

The temporary homepage used plaintext HTTP, and the temporary source URL referenced a public namespace that NearWire does not control.

Resolution: use the reserved, non-resolving `example.invalid` HTTPS namespace and document the private-lint and release-replacement semantics.

### P2: Simulator state was not restored

Package verification could boot an iPhone Simulator and leave it running after success or failure.

Resolution: record the initial simulator state, shut it down during exit cleanup only when the verifier booted it, and preserve already-booted simulators.

## Round Status

Every round 3 finding has an implemented remediation pending fresh validation and independent review.
