# Review Round 5

## Reviewers

- Architecture, module boundaries, API surface, and packaging
- Correctness, tests, reproducibility, and failure handling
- Security, supply chain, performance, documentation, and OpenSpec compliance

## Consolidated Findings

### P2: Pathless and non-source SwiftPM targets bypassed ownership checks

Targets with no dumped path were skipped, allowing implicit-path or remote binary targets outside the explicit Core and SDK ownership policy.

Resolution: require every target to be a regular or test target with an explicit, contained path. Add implicit-path and remote-binary mutation tests.

### P2: Canonical completion could precede evidence integrity

The capture pipeline checked the command but not `tee`, and published a complete manifest before verifying every log.

Resolution: check both pipeline statuses, keep the manifest in progress through log integrity verification, and publish complete only after that verification succeeds. Add forced log-write and post-capture corruption tests that require a failed manifest.

### P2: Package parity sorted order-sensitive arrays

Canonicalization sorted every array, which could hide reordered compiler flags or other ordered settings.

Resolution: preserve all array order while sorting only object keys and the explicitly name-keyed target collection. Add reversed compiler-flag coverage.

### P2: Ownership roots themselves could be symlinks

Realpath containment trusted the resolved Core or SDK directory even if that ownership root was a symlink to Viewer or an external location.

Resolution: require Core and SDK to be distinct, non-symlink directories directly below the real repository root. Add whole-root symlink mutations for SwiftPM and CocoaPods.

### P2: Canonical summary provenance was stale

The summary title and purpose described validation only through review round 3 despite containing round 4 remediation.

Resolution: identify it as round 5 validation after review rounds 1 through 4 and name the canonical run explicitly.

## Round Status

Every round 5 finding has an implemented remediation pending canonical recapture and fresh independent review.
