# Security, Performance, and Documentation Implementation Review — Round 10

Date: 2026-07-14

## Result

No actionable security, performance, privacy, or documentation finding remains in the reviewed
Round 9 remediation.

## Committed-export terminal receipt

The committed-export exception is narrow and content-free:

- The gateway enables authoritative success only for `executeExport`, and only a successful export
  candidate survives a concurrent cancellation or Store replacement
  (`ViewerStoreExplorerGateway.swift:870-888, 1092-1115`). The exporter returns success only after
  the owner-only temporary sibling has been flushed, closed, validated, and atomically renamed over
  the destination (`ViewerStoreExport.swift:330-395, 939-965`).
- `ViewerEventExplorerController` clears the prepared ticket before execution and retains only the
  exact operation identity, redacted Store token, Event count, and `Result<Void, ...>` terminal
  callback. Cancellation requests the exact gateway cancellation without removing that identity and
  moves presentation to `.cancelling` (`ViewerEventExplorerController.swift:1117-1166`). The sole
  invalid-generation allowance is passed to `finish` for that existing `.exportExecution` operation;
  the callback only selects a terminal presentation state and publishes it. It contains no query,
  mutation, ticket reuse, dynamic gateway lookup, or successor-operation call
  (`ViewerEventExplorerController.swift:1131-1147, 1902-1918`).
- Pre-commit cancellation therefore reports cancelled and preserves the prior destination, while an
  already committed success reports completed after either user cancellation or Store replacement.
  The UI disables repeat cancellation and dismissal while waiting and explicitly says that it is
  waiting for the commit-boundary result (`ViewerEventExplorerView.swift:745-810`). Runtime sealing
  still cancels the exact operation, clears export presentation and prepared state, and joins claimed
  controller work without allowing the late callback to repopulate the sealed controller
  (`ViewerEventExplorerController.swift:1230-1276, 1921-1925`). The combined runtime shutdown also
  seals and joins the originating gateway generation before closing or reopening its Store.

The focused controller tests exercise cancellation before commit, cancellation after commit, and
Store replacement after commit. They assert prior/replaced destination bytes, truthful terminal
presentation, zero controller work, and zero gateway operations. The replacement-after-commit test
also proves that only a later explicit change request uses the successor generation. No terminal
receipt itself retargets the successor Store.

## Traversal delivery, bounds, and cleanup

Release, query replacement, tail page, and gap stages now carry an immutable Store-operation token.
Each successor gateway call requires both the same coordinator generation and still-valid
predecessor delivery cell; a rejected predecessor returns `storeReplaced` without executing the
successor query (`ViewerEventExplorerCoordinator.swift:45-148` and
`ViewerStoreExplorerGateway.swift:509-526`). Every stage owns one lock-protected delivery box and one
work-tracker identity. Invalid delivery retires that identity without applying its page/detail state
or starting a following stage, and `waitForIdle` joins a callback that already queued MainActor work
(`ViewerEventExplorerCoordinator.swift:358-410, 495-590`).

The gateway retains at most 16 operations per generation, seals queued entries, interrupts the exact
active operation, waits its completion group, and closes the arbiter before delivering deferred
rejections (`ViewerStoreExplorerGateway.swift:530-565, 927-964, 993-1045`). A delivery box retains
only one content-free wrapper token. The externally reflectable gateway token, gateway, coordinator,
and work tracker all expose redacted mirrors. A blocked MainActor can therefore retain only the
finite admitted stage results, and runtime cleanup joins their tracker identities. No new
request-proportional task chain, unbounded token collection, or unjoined content-bearing result was
identified.

## Privacy, documentation, and repository boundaries

The export disclosure remains accurate and complete: Event/App data may identify people or secrets,
the JSON is unencrypted, aliases are pseudonyms rather than redaction, the file is outside Viewer
quota/retention/cleanup, its provider may synchronize or back it up, transient rows are excluded,
and NearWire does not remember the destination (`ViewerStoreExport.swift:23-40` and
`ViewerEventExplorerView.swift:820-849`). Secure temporary-file creation, nonsymlink and inode/owner/
mode validation, pre-commit cleanup, and same-directory atomic replacement remain unchanged.

Targeted scans found no received/stored Event logging, analytics, preferences, restoration, drag,
share, or clipboard path. The only Viewer pasteboard use outside operator-owned text editing remains
the explicit pairing-code copy action. The Event inspector remains display-only and the JSON export
remains the separately disclosed release boundary.

The updated design, Event Explorer capability, local-store capability, operator documentation, and
UI all describe the same `cancelling` state, pre-commit preservation rule, authoritative committed
success, exact terminal-receipt exception, predecessor-token traversal rule, and joined cleanup.

The repository still has only the root `Package.swift` and root `NearWire.podspec`. The root package
has no external dependency or Viewer target, remains Swift 5 with iOS 16/macOS 13 declarations, and
the Viewer project remains macOS 13/Swift 5 with one local root-package product, no remote package,
and no shell-script build phase.

## Independent validation

- Round 9 traversal/export focused set: 13 tests passed, 0 failures.
- Five core traversal/commit-boundary races repeated ten times: 50 executions passed, 0 failures.
- Strict OpenSpec validation with telemetry disabled: passed.
- Strict recursive Swift format lint: passed.
- `swift package --disable-sandbox dump-package`: passed; user-cache warnings were environmental
  only.
- Project, Info.plist, and entitlement plist parsing: passed.
- `git diff --check`: passed.

Configured distribution signing and validation of entitlements embedded in a signed product remain
explicitly deferred to the Goal-level `release-hardening` change and are not findings in this review.

**Unresolved findings: 0**
