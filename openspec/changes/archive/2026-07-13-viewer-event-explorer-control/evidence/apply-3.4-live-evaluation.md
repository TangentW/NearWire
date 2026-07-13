# Task 3.4 Live Evaluation Evidence

Date: 2026-07-13

## Implemented contract

- `ViewerLiveEventEvaluator` consumes exactly one immutable `ViewerLiveProjectionSnapshot` and one
  validated runtime/device/filter request. Exact selected-device scope uses 1 through 16 connection
  IDs or All Devices; it never constructs or guesses a durable row ID.
- Request construction reuses the SQLite query compiler's bounded predicate validation and shared
  JSON Path parser. Event type, literal content, App identifier/version, direction, priority,
  inclusive Viewer receive time, JSON path existence, typed scalar equality/value OR, string
  containment, gap, drop, and terminal-disposition predicates therefore use one closed grammar.
  Predicate dimensions combine with AND and selected values within one dimension combine with OR.
- Metadata and JSON string equality use exact UTF-8 bytes, including canonically equivalent but
  byte-distinct Unicode, matching SQLite's binary comparison rather than Swift's canonical String
  equality. JSON integer/real/boolean/null types remain distinct.
- A durable device-row predicate has no transient representation and is a non-match. Missing App,
  version, JSON path, gap, drop, or disposition projection data is also a non-match.
- FTS5 is deliberately not reimplemented. Any live request containing `.fullText` completes with no
  transient matches and the fixed guidance `Full-text search requires recorded data — transient
  rows excluded.` The exact durable SQLite query still participates normally.
- Evaluation rejects a snapshot outside 512 Events, 32 MiB, or 16 sessions. It permits at most
  16,384 predicate checks, 1,000,000 JSON-node visits, and strictly less than 100,000,000 elapsed
  monotonic nanoseconds. Cancellation/time checks occur before work, between entries and
  predicates, after literal scans, and at every JSON path component.
- Cancellation returns only `.cancelled`; any count, byte, shape, clock, or deadline exhaustion
  returns the one fixed `.refineRequired` result. A partial match array is never returned as
  complete. The exact maximum 512-by-32-predicate shape completes with 16,384 predicate checks; a
  16-component path records 262,144 bounded JSON visits.
- Requests, device scopes, evaluators, outputs, JSON paths, snapshots, and Event keys retain
  content-free/redacted reflection. Complete outputs carry only exact journal keys and counters, not
  copied Event content.

## Focused and differential validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests/testLiveEvaluatorMatchesMetadataJSONPresenceAndExcludesTransientFullText -only-testing:NearWireViewerTests/ViewerFoundationTests/testLiveEvaluatorReturnsNoPartialCompletionOnCancellationDeadlineOrShapeOverflow -only-testing:NearWireViewerTests/ViewerStoreTests/testLiveEvaluatorMatchesSQLiteForSharedPredicatesAndExplicitlyExcludesFTS
```

Result: `TEST SUCCEEDED`; 3 tests executed, 0 failures.

The differential test persists and projects the same two Events, then compares exact wire-sequence
results for type equals/prefix, App/version/direction/priority/time, content literal, JSON scalar OR,
JSON path existence, JSON string containment, canonically equivalent but byte-distinct strings,
gap, drop, and terminal-disposition filters. Every shared case is equal. Durable FTS finds its
recorded row while live evaluation returns the explicit transient exclusion.

The focused bounds test additionally proves cancellation, exact 100-ms deadline rejection,
513-entry shape rejection, duplicate device-scope rejection, 33-predicate rejection, oversized JSON
index rejection, exact 16,384-predicate completion, bounded JSON visits, and no partial completion.

## Complete Viewer validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 207 tests executed, 2 tests skipped, 0 failures. One skip is the explicitly
deferred configured-signing entitlement gate. The other is the opt-in Application Support artifact
audit that requires its machine-local marker.

## Static and specification validation

- `xcrun swift-format lint --strict` passed for all production and test files affected by task 3.4.
- `git diff --check` passed.
- `env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive`
  reported `Change 'viewer-event-explorer-control' is valid`.

## Environment boundary

Configured signing and entitlement validation remains deferred to final `release-hardening` by the
user-approved Goal policy. Compilation and tests use `CODE_SIGNING_ALLOWED=NO`,
`ONLY_ACTIVE_ARCH=YES`, and `ARCHS=arm64`; this evidence does not claim configured signing passed.
