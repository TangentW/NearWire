## 1. Specification

- [x] 1.1 Define the file-panel presentation boundary, cancellation behavior, and validation scope.
- [x] 1.2 Validate proposal, design, capability delta, and tasks in strict mode.

## 2. Presentation repair

- [x] 2.1 Add a window-scoped native file-panel coordinator with weak window ownership.
- [x] 2.2 Sequence import disclosure dismissal before the open panel and close selection state on
      cancellation.
- [x] 2.3 Sequence export disclosure dismissal before the save panel while retaining and restoring
      the prepared export state.
- [x] 2.4 Add the sandbox entitlement required to read and write user-selected transfer files.

## 3. Coverage and validation

- [x] 3.1 Add focused tests for import/export presentation sequencing and controller state.
- [x] 3.1a Assert that the running Viewer carries the user-selected file read/write entitlement.
- [x] 3.2 Run focused and maintained Viewer tests plus JSON transfer round-trip coverage.
- [x] 3.3 Verify import, export, cancellation, and re-import in the running Viewer and save exact
      results under `evidence`.

## 4. Review and archive

- [x] 4.1 Run independent architecture/API, correctness/testing, and
      security/performance/documentation reviews.
- [x] 4.2 Resolve every actionable finding and run a fresh no-findings review round.
- [x] 4.3 Complete the spec-to-evidence audit and archive the change.
