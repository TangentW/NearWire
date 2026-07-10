# Review Round 7

## Reviewers

- Architecture, module boundaries, API surface, and packaging
- Correctness, tests, reproducibility, and failure handling
- Security, supply chain, performance, documentation, and OpenSpec compliance

## Consolidated Findings

### P2: The integrity regression did not reach log validation

The test used the public complete-state verifier against an in-progress fixture, so it failed on status before checking the missing log or gate identity used by production pre-publication verification.

Resolution: add a read-only in-progress verification mode and test missing sequence 09, an incorrect sequence 09 gate identity, and a complete valid in-progress log set before publication.

### P2: Additional CocoaPods build file attributes were unchecked

Custom module maps, prefix headers, header mapping roots, project headers, and on-demand resources could reference unauthorized roots or inject compilation content.

Resolution: ownership-check project header paths and forbid custom module maps, prefix headers, header mappings, prefix contents, and on-demand resources because NearWire does not require those capabilities.

### P2: CocoaPods child specs and build settings could inject code

Test specs, app specs, arbitrary compiler flags, consumer xcconfig, and arbitrary pod xcconfig could introduce sources or build-time code outside the approved dependency model.

Resolution: forbid test and app specs, compiler flags, consumer xcconfig, and other custom compilation attributes. Restrict pod xcconfig to the exact approved module, strict-concurrency, and warnings-as-errors keys and values, recursively at every specification and platform level.

## Round Status

Every round 7 finding has an implemented remediation pending canonical recapture and fresh independent review.
