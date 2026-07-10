# Review Round 8

## Reviewers

- Architecture, module boundaries, API surface, and packaging
- Correctness, tests, reproducibility, and failure handling
- Security, supply chain, performance, documentation, and OpenSpec compliance

## Consolidated Findings

### P2: Legacy CocoaPods xcconfig bypassed build-setting policy

The deprecated `xcconfig` attribute was separate from user and pod target xcconfig and remained unchecked.

Resolution: forbid legacy xcconfig at root, subspec, and platform levels, with a mutation for every scope.

### P2: Distribution semantics were not locked by manifest validation

Successful builds did not prove product names and memberships, target graph, platform minima, Swift language mode, module name, default subspec, or source/dependency mappings.

Resolution: add a distribution contract checker for the complete SwiftPM and CocoaPods contract and mutation-test every invariant. Add an explicit `NearWire` pod module name.

### P2: Unknown CocoaPods DSL and linkage attributes were accepted

The denylist allowed unknown attributes, forced linkage, and undeclared frameworks, weak frameworks, or libraries.

Resolution: enforce root, subspec, and platform attribute allowlists; preserve default CocoaPods linkage; reject undeclared link dependencies; and document that any expansion requires a reviewed contract change.

## Zero-Finding Dimension

The correctness and testing reviewer reported zero unresolved findings for evidence publication, failure branches, platform tests, cleanup, parity, and existing mutation coverage.

## Round Status

Every round 8 finding has an implemented remediation pending canonical recapture and fresh independent review.
