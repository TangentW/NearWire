# Security, Performance, and Documentation Implementation Review — Round 13

Date: 2026-07-14

## Decision

No actionable security, privacy, performance, lifecycle, packaging, or documentation finding
remains in the current final diff. This review re-read the current source and corrected evidence,
independently inspected the authoritative result bundles and raw diagnostics, and did not rely on
the Round 12 conclusion.

Configured distribution signing and validation of entitlements embedded in a signed product remain
explicitly deferred to the Goal-level `release-hardening` change by product-owner decision. This
review does not claim that deferred gate passed, and the deferral is not a finding in this change.

## Round 12 remediation and final pool ownership

The three current remediation artifacts now agree with the final source:

- `evidence/implementation-review-round11-remediation.md` preserves the original 19-fixture
  discovery, then records the broadened final audit.
- `evidence/validation-6.9-aggregate.md` uses the final ownership decomposition and the authoritative
  result and diagnostics paths rather than the earlier malformed DerivedData-plus-`/tmp` path.
- `evidence/implementation-review-round12-remediation.md` records the same final metrics and makes
  clear that another independent review was still required.

The final `ViewerStoreTests.swift` contains 72 retained named `ViewerSQLitePool` constructor sites.
The 70 defer-eligible `pool`, `verification`, and `setupPool` sites have immediately matching,
exception-safe deferred closes. The other two sites are the deliberate `first` and `reopened`
fixtures in `testReadersOpenOnlyAfterSchemaAcceptanceAndNeverOnMigrationRejection`; each closes
explicitly before the next reopen or fault-injection operation can throw
(`ViewerStoreTests.swift:78-79, 117-118, 170-198, 254-259, 5839-5840, 9442-9443, 9886-9887`).
The function-scope audit therefore reports 72 owned sites, 70 defer closes, two sequencing-point
explicit closes, and zero missing owner. `ViewerSQLitePool.close()` synchronously closes the export
reader, query reader, and writer, and the connection close path clears its pointer before the
idempotent SQLite close (`ViewerSQLite.swift:498-512, 874-882`).

The authoritative full result remains:

```text
/tmp/NearWire-Round11-FinalPoolOwnership.xcresult
totalTestCount: 276
passedTests: 274
skippedTests: 2
failedTests: 0
expectedFailures: 0
result: Passed
```

Its authoritative exported diagnostics remain:

```text
/tmp/NearWire-Round11-FinalPoolOwnership-Diagnostics
```

A fresh raw scan for `BUG IN CLIENT OF libsqlite3`, `API violation`, `vnode unlinked`, and
`invalidated open fd` exited 1 with zero matches. The evidence correctly describes exit 1 as the
expected no-match result, not as a failed gate. No stale
`/tmp/NearWire-Round11-Full-Remediated.xcresult` or malformed DerivedData result reference remains in
the three corrected artifacts.

## Security, privacy, performance, and lifecycle verification

- Export preflight and UI disclose sensitive Event content, pseudonym-not-redaction aliases,
  unencrypted JSON, external retention ownership, and possible destination-provider backup before
  the save panel opens. The destination is not persisted. The exporter creates an owner-only
  nonsymlink sibling with `openat`/`O_EXCL`/`O_NOFOLLOW`, validates descriptor, leaf, owner, link,
  mode, and parent identity, writes in bounded chunks, and uses one `renameat` commit point
  (`ViewerStoreExport.swift:23-40, 330-395, 873-965`;
  `ViewerEventExplorerView.swift:730-906`).
- Export cancellation retains exact operation identity through the commit seal. Pre-commit
  cancellation preserves the prior destination; a committed replacement remains authoritative
  across cancellation or Store replacement. The gateway caps retained operations at 16,
  invalidates predecessor delivery before replacement, interrupts exact active work, joins the
  completion group, and closes the arbiter before Store teardown
  (`ViewerStoreExplorerGateway.swift:47-59, 470-534, 537-570, 877-971, 1000-1122`).
- Received or stored Event text is noneditable, nonselectable, cannot become first responder, has
  no menu or drag registration, and validates no responder command. Source scans found no Event
  logging, analytics, restoration, share, drag, clipboard export, or Event-content preference sink.
  The only explicit Viewer pasteboard write outside operator editors is the pairing-code copy action
  (`ViewerTextControls.swift:182-250`; `ViewerApplicationModel.swift:102-105`).
- Presentation, live ingress, live evaluation, renderer, composer, query, catalog, export, and
  gateway limits remain explicit in production code. Tests cover 100,000 live offers, bounded
  gateway replacement, renderer/composer replacement and claimed-delivery cleanup, migration
  resource limits, export commit races, and runtime shutdown without retaining content. Diagnostic
  wall time and whole-process memory remain documented as host context rather than product
  guarantees.
- The root package has zero external dependencies, targets iOS 16 and macOS 13 in Swift 5 language
  mode, and has no Viewer target. The Viewer project has one local root-package reference, no remote
  package reference or shell build phase, and keeps macOS 13, Swift 5.0, complete strict concurrency,
  sandbox, hardened runtime, and the configured entitlement source. The Core wire-carrier additions
  remain in `NearWireInternal` SPI and keep descriptions and reflection content-free.
- `Documentation/Viewer-Local-Store.md` accurately states owner-only local files, no NearWire
  application-layer database encryption, FileVault's conditional role, and secure-delete
  limitations. `Documentation/Viewer-Event-Explorer.md` matches the UI and implementation on export
  disclosure, transient-row exclusion, commit semantics, bounded presentation, privacy, cleanup,
  and diagnostic-only performance measurements.

## Independent validation

- The authoritative full result and raw diagnostics were independently read and scanned: 276 total,
  274 passed, two configured skips, zero failed, and zero SQLite misuse matches.
- The three original SQLite lifecycle reproducers were rerun against the current source for five
  iterations each: 15 executions, zero failures. Result bundle:
  `/tmp/nearwire-r13-spd-20260714.xcresult`. Exported diagnostics:
  `/tmp/nearwire-r13-spd-20260714-diagnostics`; the same raw misuse scan exited 1 with zero matches.
- `git diff --check`, strict OpenSpec validation, recursive strict Swift format lint, source plist
  lint, and root `swift package dump-package` all passed. The package dump confirmed zero
  dependencies, iOS 16, macOS 13, Swift 5, and no Viewer product or target.
- Project scans confirmed one local Swift package reference, no remote package reference, no shell
  build phase, and the expected Viewer build settings.

## Unresolved finding count

**0**
