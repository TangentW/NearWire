## 1. Specification

- [x] 1.1 Define the four-character grammar, compatibility boundary, UI size, and audit scope.
- [x] 1.2 Validate proposal, design, capability deltas, and tasks in strict mode.

## 2. Canonical grammar and generation

- [x] 2.1 Change the shared Core canonical length to four and update safe SDK validation guidance.
- [x] 2.2 Update Core, SDK discovery/admission/lifecycle, and transport fixtures to four characters.
- [x] 2.3 Keep SDK UI raw-input ownership independent and verify its tests contain no six-character
      canonical assumption.

## 3. Viewer and Demo

- [x] 3.1 Update Viewer generator/listener fixtures to four characters.
- [x] 3.2 Increase the Viewer pairing-code font from 30 to 36 points and validate header layout.
- [x] 3.3 Audit Demo source, UI tests, package integration, project configuration, and maintained
      fixtures for canonical-length assumptions.

## 4. Documentation and validation

- [x] 4.1 Update current READMEs and product documentation without rewriting archived history.
- [x] 4.2 Run focused and complete maintained tests/builds, packaging checks, formatting, repository
      residue scans, and strict OpenSpec validation.
- [x] 4.3 Save exact results under the change evidence directory.

## 5. Review and archive

- [x] 5.1 Run independent architecture/API, correctness/testing, and
      security/performance/documentation reviews.
- [x] 5.2 Resolve every actionable finding and run a fresh no-findings review round.
- [x] 5.3 Complete a spec-to-evidence audit and archive the change.
