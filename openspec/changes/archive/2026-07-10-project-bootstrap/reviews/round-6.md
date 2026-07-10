# Review Round 6

## Reviewers

- Architecture, module boundaries, API surface, and packaging
- Correctness, tests, reproducibility, and failure handling
- Security, supply chain, performance, documentation, and OpenSpec compliance

## Consolidated Findings

### P1: A test environment variable could forge complete evidence

The production capture command accepted a test-only environment variable that skipped every real gate while still writing logs and a complete canonical manifest.

Resolution: remove all command-skipping behavior from the production path, add immutable gate identities to canonical logs, and add a regression proving the old environment variable cannot skip the real environment gate or complete a run.

### P2: Platform-specific pod attributes bypassed validation

CocoaPods can serialize dependencies and source paths below platform proxy hashes such as `ios`; only top-level specification attributes were checked.

Resolution: recursively validate every supported platform attribute tree for dependencies and owned path-bearing attributes. Add platform-specific external dependency and unauthorized source mutations.

### P2: CocoaPods binary and executable hooks bypassed isolation

Vendored frameworks or libraries could add runtime code without a pod dependency, while prepare commands and script phases could execute supply-chain code during integration.

Resolution: reject vendored frameworks, vendored libraries, prepare commands, and script phases at root, subspec, and platform levels. Add root, subspec, and platform mutations.

## Round Status

Every round 6 finding has an implemented remediation pending canonical recapture and fresh independent review.
