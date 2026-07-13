# Implementation Review Round 12 Remediation

Date: 2026-07-14

## Result

The one round-12 security/performance/documentation finding is remediated. Saved evidence now
distinguishes the original 19-fixture reproduction from the broadened final audit, records all 72
retained named `ViewerSQLitePool` constructor sites as 70 immediate matching defer closes plus two
sequencing-point explicit closes, and references the authoritative final result and diagnostic
paths. A fresh three-discipline review is required before this change can close.

Configured distribution signing and validation of entitlements embedded in a signed product remain
explicitly deferred to the Goal-level `release-hardening` change by product-owner decision. This
remediation does not claim that deferred gate passed.

## SPD-R12-001 — final SQLite ownership evidence

- `implementation-review-round11-remediation.md` now records the complete ownership-hardening
  timeline: 19 initially affected direct fixtures, followed by an audit of every retained named
  pool construction.
- `validation-6.9-aggregate.md` now records 72 retained named constructors, comprising 70 immediate
  matching defer closes and two deliberate sequencing-point explicit closes, with zero missing
  owner instead of stopping at the original 19-fixture scope.
- Both files now reference `/tmp/NearWire-Round11-FinalPoolOwnership.xcresult` as the authoritative
  complete result and `/tmp/NearWire-Round11-FinalPoolOwnership-Diagnostics` as its diagnostic
  export. The malformed DerivedData-plus-`/tmp` path was removed.
- The final complete result contains 276 total tests, 274 passes, two configured skips, and zero
  failures. The raw diagnostic gate has zero matches for `BUG IN CLIENT OF libsqlite3`,
  `API violation`, `vnode unlinked`, or `invalidated open fd`.

The exact constructor-site audit reports:

```text
retained named ViewerSQLitePool constructor sites: 72
immediate matching defer closes: 70
sequencing-point explicit closes: 2
missing retained named owners: 0
```

## Fresh validation after the evidence correction

```text
swift test
Executed 537 tests, with 0 failures

xcodebuild build -workspace NearWire.xcworkspace -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
** BUILD SUCCEEDED **

swift package dump-package
exit 0
no dependencies; iOS 16; macOS 13; Swift 5; no Viewer target

xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
exit 0

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
Change 'viewer-event-explorer-control' is valid

plutil -lint Viewer/NearWireViewer/Resources/Info.plist \
  Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy \
  Viewer/NearWireViewer/Resources/NearWireViewer.entitlements
all three files: OK
```
