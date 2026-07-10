# Review Round 9

## Reviewers

- Architecture, module boundaries, API surface, and packaging
- Correctness, tests, reproducibility, and failure handling
- Security, supply chain, performance, documentation, and OpenSpec compliance

## Consolidated Findings

### P2: Pod source and provenance metadata were not locked

The contract allowed homepage, Git source, tag strategy, license, and author identity to drift while private lint intentionally skipped remote ownership verification.

Resolution: lock the reserved bootstrap homepage and Git URL, require the source tag to equal the product version with no other source keys, and lock proprietary license and author identity. Add hostile Git, HTTP archive, branch, commit, tag, homepage, license, and author mutations.

### P2: SwiftPM product and target descriptors were projected lossy

The initial contract ignored library linkage, dependency conditions, build settings, plugin usage, resources, and exclusions.

Resolution: compare exact automatic-library product descriptors and exact target descriptors. Add dynamic/static linkage, conditional dependency, unsafe Swift/C/linker flags, plugin, resource, and exclusion mutations.

### P2: Pod dependency constraints and additional mappings were omitted

Dependency keys were compared without version constraints, while root or platform-specific source mappings could be added outside the expected subspec mapping.

Resolution: compare complete normalized subspec descriptors, including dependency values and the absence of extra platform attributes, and explicitly require root path mappings to remain absent. Add constraint, root source, and platform source mutations.

## Zero-Finding Dimension

The correctness and testing reviewer reported zero unresolved findings for the implemented distribution checker, allowlist, canonical evidence, platform tests, cleanup, parity, and task accuracy before these additional contract-hardening findings.

## Round Status

Every round 9 finding has an implemented remediation pending canonical recapture and fresh independent review.
