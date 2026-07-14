## 1. Change Gate

- [x] 1.1 Complete and strictly validate the proposal, design, capability delta, and task plan
  before modifying production or test source.

## 2. Entitlement Fix

- [x] 2.1 Add the network-client entitlement to the maintained Viewer sandbox profile while
  preserving the existing sandbox and network-server capabilities.
- [x] 2.2 Update the signed-process entitlement regression and affected Viewer documentation to
  require the exact maintained profile and continue rejecting unrelated capabilities.

## 3. Validation and Evidence

- [x] 3.1 Run the focused signed entitlement regression and the complete Viewer test suite.
- [x] 3.2 Build a signed Viewer, inspect final entitlements and packaged local-network metadata, and
  record the successful real-iPhone NECP/TLS evidence.
- [x] 3.3 Run strict OpenSpec validation, `git diff --check`, and a spec-to-evidence audit.

## 4. Review and Completion

- [x] 4.1 Obtain independent architecture/API, correctness/testing, and
  security/performance/documentation reviews; resolve every actionable finding and repeat until a
  final review round has no unresolved findings.
- [x] 4.2 Archive the validated change, verify canonical specifications, commit only the scoped
  files, and push the current branch.
