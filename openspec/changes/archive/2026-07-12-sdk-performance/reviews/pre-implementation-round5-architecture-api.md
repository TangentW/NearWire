# Pre-Implementation Round 5 Architecture and API Review

Date: 2026-07-12

## Scope

Independently reviewed all current active `sdk-performance` proposal, design, capability specifications, tasks, prior architecture/API reports, and remediation records. This review specifically rechecked the Round 4 failure-cleanup receipt remediation and regressed every earlier architecture/API finding. This report is the only file modified.

## Findings

**Zero actionable findings.**

## Verification

### Failure cleanup remains serialized and implementable

The Round 4 correctness finding is resolved without widening the supported API. A current-run sampling or submission failure now invalidates its exact run and installs the same internal Stopping barrier used by explicit stop, with one cleanup token, one nonthrowing cleanup Task/receipt, and a pending Failed terminal target. The run worker owns predecessor handles, releases every task-owned external resource, and emits the exact receipt only as its final step. Actor receipt validation is therefore the sole point that may discard the predecessor Task handle and publish Failed.

The reentrant operations have a total contract. Start during failure cleanup acquires no successor resource, awaits the exact receipt, checks only its own cancellation, and then begins or joins one fresh Starting attempt. Stop during failure cleanup joins the same barrier, changes the pending target to Stopped, and suppresses Failed. Duplicate stops share cleanup, duplicate starts converge after cleanup, and stale receipts cannot publish a terminal state or release successor resources because every completion revalidates its token and predecessor-owned handles. No public Failed value is visible while task-owned predecessor resources remain live.

This design keeps Idle, Starting, Running, and Stopping as private implementation phases while preserving the supported Stopped, Running, and Failed state surface. The receipt is an internal synchronization boundary rather than a new public state, callback, or ownership concept.

### Earlier architecture and API findings remain resolved

- The supported surface remains limited to configuration, typed content-safe error, public lifecycle state, and the instance-based monitor. Core snapshots, metrics, collectors, clocks, leases, display-link proxies, and test seams remain internal.
- `currentState` remains the actor-isolated authoritative state. The nonisolated `states` property is justified only by a bounded, immediately current-yielding hub with exact subscriber removal, no history, and no monitor retention.
- Starting provides one exact attempt, shared outcome and cancellation semantics, token checks before acquisition and commit, and stale-attempt isolation. Stopping provides one exact predecessor cleanup barrier, successor gating, and terminal winner rules.
- The exact per-`NearWire` lease enforces one active monitor without introducing a global singleton API. Construction remains side-effect free, running start is idempotent, failed restart is fresh, and macOS fails before lease or collector acquisition.
- Battery monitoring remains an explicitly documented best-effort App-global policy. Managed mode coordinates only NearWire claims and does not fight observable external disablement; unmanaged mode never mutates host state.
- Display collection has a coherent context boundary: it estimates main-display callback cadence but does not expose or infer maximum FPS without a view/window screen context. Deprecated or guessed screen lookup remains prohibited.
- The metric inventory, unavailable precedence, CPU baseline, transport diagnostics, keep-latest delivery, and fixed safe errors remain closed and do not leak unsupported implementation types through the API.
- SwiftPM and CocoaPods expose equivalent supported Performance declarations. The optional module remains absent from the default SDK integration, platform implementation remains under SDK, and the separate base and Performance privacy resources preserve component ownership.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: **PASS** (`Change 'sdk-performance' is valid`).
- `./Scripts/verify-english.sh`: **PASS** (`CJK character scan passed. Human review remains required for semantic language compliance.`).
- `git diff --check -- openspec/changes/sdk-performance`: **PASS**.

## Verdict

**Pre-implementation architecture/API approval granted. Unresolved actionable finding count: 0.**
