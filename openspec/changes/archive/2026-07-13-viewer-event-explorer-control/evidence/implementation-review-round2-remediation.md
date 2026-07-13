# Implementation Review Round 2 Remediation

Date: 2026-07-14

## Result

The two round-2 findings, representing one cancellation-cleanup race reported by two reviewers and
one independent live-session transition race, were remediated. The focused regressions, complete root
package suite, complete unsigned Viewer suite, formatting, diff hygiene, and strict OpenSpec
validation pass. A fresh three-dimension implementation review is still required before tasks 7.1 or
7.2 may be checked.

Configured signing and embedded-entitlement verification remains deferred to Goal-level
`release-hardening` by the product-owner decision and is not treated as a round-2 finding.

## ARCH2-001 and CT-R2-001 — completion-ordered cancellation registration

- The explorer gateway now registers exact operation cancellation while holding the same generation
  lock that completion must acquire before removing the operation and clearing its reader state.
- Completion therefore observes one strict order: cancellation registration occurs before the final
  per-reader clear, or completion removes the operation before a later cancellation can find it.
- `sealAndWait` uses the same ordering before it joins originating work.
- Query and export services expose test-only counts for remembered operation UUIDs. The regression
  blocks cancellation registration, releases operation execution, and proves completion cannot pass
  the gateway boundary early. After registration resumes, both query and export reader counts return
  to zero. The same interleaving is repeated for sealing/replacement.

## SPD-R2-001 — independently bounded terminal session transitions

- Pending session-start metadata and session termination are now separate dictionaries, each bounded
  to the 16-session product limit and coalesced by exact connection ID.
- A new session start can no longer evict the only terminal transition for an already-projected
  session.
- Each drain applies terminal transitions to projected sessions before admitting new Events. This
  makes ended sessions reclaimable before replacement sessions need capacity.
- A termination whose start and first Event are in the same drain is deferred within that drain and
  applied after session materialization. A termination with no matching session is disclosed as
  diagnostic loss instead of being retained without bound.
- The regression projects 16 initial sessions and Events, blocks the projection executor, queues all
  16 terminal transitions, then queues 16 replacement starts and Events. Before release it proves
  both pending maps are exactly 16; afterward it proves only the 16 replacements and their Events are
  resident and exactly 16 displaced old Events are disclosed as window overflow.

## Validation

Focused regressions:

```text
ViewerFoundationTests.testLiveSessionMetadataStaysBoundedAndFreshActiveSessionSurvivesChurn
ViewerFoundationTests.testBlockedProjectionRetainsTerminalTransitionsBeforeReplacementSessions
ViewerStoreTests.testSQLiteOperationCancellationNeverInterruptsAnActiveSuccessor
ViewerStoreTests.testExplorerGatewayCancellationIsQueuedCompletedAndActiveSuccessorSafe
ViewerStoreTests.testGatewayRegistersCancellationBeforeCompletionClearsEveryReader
ViewerStoreTests.testExplorerGatewayFreezesPreflightedExportsAndCancellationPreservesDestination
Executed 6 tests, with 0 failures
```

Complete root package suite:

```text
swift test
Executed 537 tests, with 0 failures
```

The sandboxed first invocation could not write the user Clang module cache. The identical command was
rerun with module-cache write access and passed. No source, test, or gate was changed for the retry.

Complete unsigned Viewer suite:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
Executed 243 tests, with 2 tests skipped and 0 failures
** TEST SUCCEEDED **
```

The result bundle is:

```text
/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/
  Logs/Test/Test-NearWireViewer-2026.07.14_00-03-23-+0800.xcresult
```

The full Viewer run repeated the 100,000-Event/10,000-gap migration gates:

```text
heap-growth=22249496
database-high-water=26894336
wal-high-water=0
temp-high-water=0
samples=6

cancellation-acknowledgement-ns=100660917
cancellation-heap-growth=245760
database-high-water=26894336
wal-high-water=0
temp-high-water=0
samples=2
```

The assertions gate no more than 128 MiB heap growth and no more than 250 ms injected cancellation;
the observed values remain diagnostic host context only.

Static gates:

```text
xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
exit 0

git diff --check
exit 0

openspec validate viewer-event-explorer-control --strict
Change 'viewer-event-explorer-control' is valid
exit 0
```

The OpenSpec command emitted only a failed optional analytics flush because network access is
restricted; local validation completed with exit 0. No shell harness was added and no validation gate
was weakened.
