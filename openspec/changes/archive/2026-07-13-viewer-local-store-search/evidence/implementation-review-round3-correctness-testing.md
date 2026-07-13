# Implementation Review Round 3 — Correctness and Testing

Date: 2026-07-13

## Scope

This fresh independent review traced the stable Round 3 `viewer-local-store-search` snapshot through runtime-generation ownership and late cleanup, shared preparation/ingress budgeting, duplicate peer Event UUID terminal ownership, immutable gap accounting, write failure and explicit retry, shutdown flush/resource release, exact quota admission and bounded reclaim, frozen query/export membership, lease and cancellation commit races, and the current tests/evidence. No production, test, specification, or documentation source was modified.

Severity meanings:

- **High:** a required lifecycle, capacity, or query contract is materially false and can prevent valid durable admission, lose required journal state, or return semantically incorrect results.
- **Medium:** a bounded but actionable correctness, validation, or evidence gap that must be resolved before completion.

Configured signing, entitlement assertions, and the stable-signer update probe are explicitly deferred by the user and are not findings in this review.

## Round 2 disposition

The stable Round 3 snapshot resolves the Round 2 shutdown/flush, annotation-confirmation, gap aggregation/range, disposition-aware reclaim, export commit/cancellation, and broad evidence findings. It also resolves the original projected-capacity defect for the Event bytes supplied to cleanup, the missing query dimensions and Viewer receive-time semantics, strict JSON scalar typing, distinct work-limit reporting, generation-bound late-runtime cleanup, and mid-runtime nondurable-device accounting.

The original capacity finding remains narrowly but materially incomplete because the cleanup projection does not cover the whole transaction. The query implementation is functionally broader, but its closed input validator still does not enforce two specified grammars.

## Findings

### NW-LSS-IMPL-R3-CT-001 — High — Capacity recovery projects only part of each transaction's quota reservation

`appendEvents` supplies cleanup with only the sum of each Event row's `observation.quotaBytes` (`ViewerEventStore.swift:400-410`), but the same transaction may reserve another structural row for every non-`nil` initial disposition (`ViewerEventStore.swift:960-982`). Recording creation reserves both the base recording and its initial version (`ViewerEventStore.swift:285-318,760-791`), device creation may reserve a new installation alias plus the device base and initial version (`ViewerEventStore.swift:321-389,735-757,794-824`), and every structural mutation enters `writeTransaction` with its default planned reservation of zero (`ViewerEventStore.swift:414-415,1019-1054`). Cleanup decides whether capacity work is required from committed quota plus that supplied projection (`ViewerStoreMaintenance.swift:425-457`).

Consequently, a transaction can roll back on a later reservation, ask cleanup to project an amount that still fits exactly at or below capacity, select no eligible closed recording, retry once, and enter `capacityPaused` even though reclaimable history exists. A deterministic example is current quota `capacity - observation.quotaBytes`: the Event reservation fits exactly, its 512-byte initial disposition crosses capacity, but recovery projects only the Event bytes and therefore sees no crossing. Structural starts/closes, aliases, gaps, policy/drop samples, and duplicate/no-op mutations have the same class of underprojection or reserve-before-idempotency problem. The current projected-admission test places quota at `capacity - 512` and proves only that an Event-row projection can trigger cleanup (`ViewerStoreTests.swift:1265-1334`); it does not cover a later reservation in the same transaction or any structural transaction.

**Required resolution:** compute a checked, exact whole-transaction reservation before the first mutation and pass it to recovery, including conditional alias and initial-disposition rows and the actual text reservation for gaps. Ensure idempotent duplicate/no-op writes are recognized without requiring capacity or deleting unrelated history. Add boundary tests where the Event itself fits but its initial disposition crosses; recording/device creation crosses on a later row; new versus existing alias changes the reservation; close/policy/drop/gap mutations cross; a duplicate is a no-op at full capacity; and eligible versus protected history produces the correct admit/pause result.

### NW-LSS-IMPL-R3-CT-002 — Medium — The closed query validator accepts invalid Event-type filters and non-ASCII JSON array indexes

Exact, OR-list, and prefix Event-type predicates use only the generic nonempty/control/512-byte search-text validator (`ViewerStoreQuery.swift:62-83,282-290`). They therefore accept values that the Event model rejects, including overlength types, leading digits, empty dot segments, non-ASCII segments, and punctuation; the Core grammar instead requires at most the Event-type byte limit and dot-separated ASCII segments beginning with a letter (`EventType.swift:70-99`). This contradicts the required validated exact/prefix behavior (`spec.md:188-194`; `design.md:138-140`). The prefix grammar needs its own explicit rule so supported prefixes such as the existing `"test."` case remain valid while impossible Event-type prefixes are rejected.

The JSON path validator similarly consumes array indexes with `Character.isNumber` (`ViewerStoreQuery.swift:239-275`). That admits non-ASCII numerals such as `$.a[١]`, which SQLite rejects at execution as `bad JSON path` rather than the compiler rejecting through the closed grammar. Current compiler tests cover quoted bracket notation, term limits, and controls but neither Event-type grammar failures nor non-ASCII index cases (`ViewerStoreTests.swift:432-470`).

**Required resolution:** implement explicit equality and prefix validators derived from the Event-type grammar and byte limit, and restrict JSON array indexes to the ASCII digits accepted by SQLite. Add compiler truth tables for valid full types, partial/trailing-dot prefixes, reserved platform types, maximum length, leading digits, empty segments, Unicode/punctuation, ASCII indexes, non-ASCII numeric characters, component count, and byte bounds; assert invalid inputs fail before query-plan or SQLite execution.

## Validation Results

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
# no output; exit 0

xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWireViewerDerived ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache \
  SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache \
  test -only-testing:NearWireViewerTests/ViewerStoreTests
Test Suite 'ViewerStoreTests' passed.
Executed 35 tests, with 0 failures (0 unexpected).
** TEST SUCCEEDED **
```

The focused suite is green and the current Round 3 validation evidence records 112 unsigned Viewer tests plus 531 root Swift package tests passing. Those results do not exercise the exact later-reservation capacity boundaries or the invalid compiler inputs above. Configured-signing, entitlement, and stable-signer checks remain deferred by user direction and are not counted as failures or findings.

## Verdict

**Approval withheld. Exact unresolved actionable finding count: 2 — 1 High, 1 Medium, 0 Low.**

Round 3 closes the lifecycle, ownership, immutable-history, frozen traversal, cancellation, and most testing gaps from Round 2. Completion is still blocked by incomplete whole-transaction quota projection and two closed-query grammar holes.
