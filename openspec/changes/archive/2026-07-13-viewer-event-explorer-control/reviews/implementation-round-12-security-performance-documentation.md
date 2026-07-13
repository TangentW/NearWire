# Security, Performance, and Documentation Implementation Review — Round 12

Date: 2026-07-14

## Decision

One actionable documentation/evidence finding remains. The final SQLite fixture ownership change,
export boundary, traversal ownership, privacy surfaces, resource bounds, and package boundaries have
no unresolved security, performance, privacy, or lifecycle defect in the reviewed code. However, the
saved round-11 remediation and aggregate evidence still describe an earlier, narrower fixture audit
and point at superseded or malformed result-bundle paths rather than the final validated source.

Configured distribution signing and inspection of entitlements embedded in a signed product remain
explicitly deferred to the Goal-level `release-hardening` change by product-owner decision. That
deferred gate is not a finding in this review.

## Finding

### SPD-R12-001 — P2 (confidence: 10/10): saved evidence does not describe the final pool-ownership audit or final full result

The current test source gives every one of the 70 eligible named `ViewerSQLitePool` construction
sites an immediate, exception-safe matching `defer { ...close() }`. This includes pools constructed
through both `makePaths()` and a previously prepared `paths` value, plus verification and setup
pools. The two intentional sequencing sites in
`testReadersOpenOnlyAfterSchemaAcceptanceAndNeverOnMigrationRejection` close their first and
reopened pools immediately, before any later throwing operation. Higher-level owners still perform
their explicit normal-path stop/join/close ordering, and the deferred pool close is safe when reached
again because `ViewerSQLitePool.close()` synchronously closes its three connections and is
idempotent (`ViewerStoreTests.swift:77-105, 115-168, 170-198, 5837-5867, 9235-9443`;
`ViewerSQLite.swift:874-882`). A function-scope constructor audit reports zero eligible named pool
without exception-safe cleanup.

The final full test result is
`/tmp/NearWire-Round11-FinalPoolOwnership.xcresult`: 276 total, 274 passed, two configured skips, and
zero failures. Its exported diagnostics are
`/tmp/NearWire-Round11-FinalPoolOwnership-Diagnostics`; the raw misuse scan exits 1 with zero matches
for `BUG IN CLIENT OF libsqlite3`, `API violation`, `vnode unlinked`, or `invalidated open fd`.

The saved evidence does not record that final state:

- `implementation-review-round11-remediation.md:7-24` describes only 19 direct `makePaths()`
  fixtures, while the final audit was broadened to every eligible named pool-construction site.
- `implementation-review-round11-remediation.md:61-89` still identifies the superseded
  `/tmp/NearWire-Round11-Full-Remediated.xcresult` and diagnostics directory as the complete gate.
- `validation-6.9-aggregate.md:43-48` presents a DerivedData directory and an unrelated `/tmp`
  result path as one malformed two-line source path.
- `validation-6.9-aggregate.md:184-189, 232-235` still states the narrow 19-fixture conclusion and
  says the referenced evidence contains the exact final paths, although it does not contain the
  authoritative final result above.

This does not invalidate the final test result, but it violates the repository requirement that
saved evidence match every claimed requirement and makes the final lifecycle gate non-reproducible
from the change artifacts alone.

Required remediation:

1. Preserve the historical 19-fixture correction, but record the subsequent broader audit and its
   final 70-of-70 eligible named-constructor result, including the two intentionally immediate-close
   sequencing sites.
2. Replace the stale and malformed full-result references with the authoritative final `.xcresult`
   and exported diagnostics paths, counts, exact raw scan, exit code, and zero-match result.
3. Update the aggregate ownership-correction narrative so it distinguishes the original finding,
   proactive broader hardening, and final validation rather than claiming the earlier 19-fixture run
   validates the later source.
4. Rerun strict OpenSpec validation, strict formatting lint, and diff hygiene after the evidence
   correction, then obtain a fresh independent review round.

## Security, privacy, performance, and lifecycle verification

- Export preflight truthfully discloses sensitive content, pseudonym-not-redaction aliases,
  unencrypted JSON, external retention ownership, and possible provider backup. Export uses an
  owner-only nonsymlink temporary sibling, bounded chunks, descriptor/leaf/parent validation, a
  lock-coupled cancellation/lease commit seal, and one `renameat` commit point
  (`ViewerStoreExport.swift:23-40, 330-395, 873-965`; `ViewerEventExplorerView.swift:730-906`).
- Rejected traversal successors carry delivery-invalid identity and cannot retarget a replacement
  Store. Normal generation work remains capped at 16 operations, replacement invalidates delivery,
  interrupts exact active work, joins the completion group, and closes the arbiter before deferred
  rejection (`ViewerStoreExplorerGateway.swift:47-59, 501-570, 934-971, 1000-1057`).
- Received or stored Event views are nonselectable, noneditable, have no contextual menu or drag
  registration, and validate no responder command. Source scans found no Event-content logging,
  analytics, preferences, restoration, share, drag, or clipboard sink. The only explicit Viewer
  pasteboard write outside ordinary operator editors remains the pairing-code copy action
  (`ViewerTextControls.swift:182-250`; `ViewerApplicationModel.swift:102-105`).
- The local-store guide accurately states owner-only permissions, the absence of application-layer
  database encryption, FileVault's conditional role, and secure-delete limitations. The Event
  Explorer guide and UI agree on export disclosure, commit semantics, transient-row exclusion,
  bounded presentation, and cleanup (`Viewer-Local-Store.md:17-23, 69-75`;
  `Viewer-Event-Explorer.md:219-247, 311-355`).
- The root package has no external dependency, targets iOS 16/macOS 13 in Swift 5 language mode,
  and contains no Viewer target. The Viewer project has one local root-package product, no remote
  package reference, and no shell-script build phase. The Core wire carrier additions remain under
  `NearWireInternal` SPI, keep reflection content-free, and preserve encoded wire output.

## Independent validation

- The original three-test SQLite reproduction repeated ten times: 30 executions, zero failures.
  Independent result bundle:
  `/tmp/nearwire-r12-spd-focused-escalated.xcresult`.
- Exported focused diagnostics:
  `/tmp/nearwire-r12-spd-focused-diagnostics`. The four-pattern SQLite misuse scan exited 1 with
  zero matches.
- The authoritative final full result was independently read with `xcresulttool`: 276 total, 274
  passed, two skipped, zero failed, zero expected failures. Its exported raw diagnostics also had
  zero SQLite misuse matches.
- Strict OpenSpec validation, recursive strict Swift format lint, `git diff --check`, root package
  dump, and source Info/privacy/entitlement plist lint passed. The package dump confirmed zero
  dependencies, iOS 16, macOS 13, Swift 5, and no Viewer product or target. SwiftPM emitted only
  user-cache accessibility/read-only-cache warnings; manifest evaluation succeeded with isolated
  module caches.
- The first sandboxed focused-test invocation could not write Xcode/SwiftPM caches. The identical
  cache-enabled invocation completed successfully; no test or gate was weakened.

## Unresolved finding count

1 actionable finding: SPD-R12-001 (P2 documentation/evidence consistency).
