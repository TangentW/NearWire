# Architecture and API Implementation Review - Round 12

Date: 2026-07-14

## Result

No actionable architecture, API, lifecycle, module-boundary, or compatibility finding remains in
the current change.

## SQLite test-pool ownership

`ViewerStoreTests.tearDownWithError` removes every registered temporary directory after each test
returns (`ViewerStoreTests.swift:108-112`). The round-11 remediation therefore correctly moved pool
ownership from nondeterministic ARC timing to the lexical scope of each test that retains a
temporary `ViewerSQLitePool`.

The original audit added `defer { pool.close() }` to the 19 tests that construct a pool directly
from `makePaths()`. The audit was subsequently widened to every retained named construction,
including paths held in local variables and helper scopes. The authoritative constructor-site audit
of the final source reports 72 retained named `ViewerSQLitePool` constructions: 70 defer-eligible
`pool`, `setupPool`, or `verification` sites have an immediately matching defer close, while the
sequencing fixture closes `first` and `reopened` explicitly before reopen or fault injection. The
missing-owner count is zero. Constructors used only inside expected-throw expressions retain no pool
and are outside that metric.

Tests with a higher-level owner preserve their explicit shutdown ordering: for example, the query
arbiter releases its traversal and is closed before scope exit (`ViewerStoreTests.swift:2428-2435`),
and the frozen gap export ends its query traversal before the pool defer runs (`8022-8032`).
Synchronous export and maintenance calls return before their scope closes, while runtime-owned
asynchronous paths retain their existing stop/join operations.

The cleanup primitive is suitable for this use. `ViewerSQLitePool.close()` closes export reader,
query reader, and writer in order (`ViewerSQLite.swift:874-882`). Each connection close synchronizes
on its serial queue, clears the pointer under the state lock, and calls `sqlite3_close_v2` only when
the pointer was non-nil (`ViewerSQLite.swift:498-512`). Repeated explicit/deferred/deinit closes are
therefore idempotent, and temporary-directory teardown cannot unlink an open pool connection.

The corrected round-11 remediation evidence preserves the original 19-method history and records the
subsequent authoritative 72-site ownership audit, its 30-execution focused reproduction, and the
final complete 276-test raw-diagnostic gate
(`evidence/implementation-review-round11-remediation.md:7-29, 31-108`).

## Traversal, export, and lifecycle architecture

The SQLite test-only changes do not alter production ownership or public API. The round-10 and
round-11 traversal fixes remain intact: direct no-Store generation-zero tokens remain
delivery-valid, rejected `following:` tokens carry an invalid delivery cell, each stage preserves
the exact predecessor generation, and synchronously rejected successors retire work without
mutating or retargeting presentation. Only an explicit fresh traversal can use the replacement
generation.

The commit-aware export contract is also unchanged. Pre-commit cancellation preserves the previous
destination; a successful atomic replacement remains authoritative to the still-live controller;
and the content-free terminal receipt is the only invalid-generation delivery exception. Runtime
sealing still cancels and joins the originating gateway/controller work before closing Store
resources. Fresh traversal and export-boundary tests passed against the current test binary.

No new SDK API or production dependency was introduced. The Core wire-carrier additions remain in
the existing internal SPI. The root package still has zero dependencies, declares iOS 16, macOS 13,
and Swift 5 language mode, and contains no Viewer target. The Viewer project resolves to macOS 13,
Swift 5.0, and complete strict concurrency, uses the local root-package `NearWireCore` product, and
contains no remote package or shell build phase.

## Fresh validation

- The authoritative source audit reports 72 retained named `ViewerSQLitePool` constructor sites:
  70 immediate matching defer closes, two sequencing-point explicit closes, and zero missing owner.
  Focused pool-lifecycle repetitions passed, and exported raw diagnostics had zero matches for
  `BUG IN CLIENT OF libsqlite3`, `API violation`, `vnode unlinked`, or `invalidated open fd`.
- The current complete Viewer suite passed with 276 total tests, 274 passed, two configured skips,
  and zero failures. Its freshly exported raw diagnostics had zero matches for the same SQLite API
  violation gate. Result bundle: `/tmp/NearWire-Round12-Architecture-Full.xcresult`.
- Six focused traversal-generation and export commit-boundary tests passed with zero failures.
- `git diff --check`, strict OpenSpec validation, and recursive strict Swift format lint passed
  after the final test-scope changes.
- `swift package dump-package` confirmed zero dependencies, iOS 16, macOS 13, Swift 5, and no Viewer
  target. Viewer build settings confirmed macOS 13, Swift 5.0, complete strict concurrency, sandbox,
  hardened runtime, and the configured entitlement file.
- Project, Info, and entitlement plists parsed successfully; project scans found one local package
  reference and no remote package or shell-script build phase.

Configured distribution signing and validation of entitlements embedded in a signed product remain
deferred to the Goal-level `release-hardening` change by product-owner decision and are not a
finding.

**Unresolved findings: 0**
