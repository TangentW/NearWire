# Architecture and API Implementation Review — Round 6

## ARCH-R6-001 — P1 High: runtime-end closes SQLite before joining the status worker

`closeStorage()` deactivates and joins `ViewerStoreStatusSignal` before closing the pool, but both
`runtimeEnded` completion paths close the pool directly. A queued provider can therefore use the query
reader after runtime detachment, race pool closure, and forward old-generation IDs after a replacement
coordinator is installed.

Funnel every coordinator shutdown through one idempotent owner that closes maintenance, deactivates
and joins the status signal, then closes the pool. Add blocked-provider runtime-end regressions for
both accepted and already-finished preparation paths.

## ARCH-R6-002 — P1 High: client completion can deadlock reentrant sealing

Active operations invoke arbitrary client completion before leaving the completion group. Queued
cancellation and sealing similarly invoke rejection before clearing cancellation state and leaving
the group. A callback that synchronously calls `sealAndWait` or installs a replacement waits on its
own group entry and cannot return to release it.

Retire operation ownership before invoking arbitrary client code and use the controller generation/
work owner to join presentation delivery, or add explicit current-callback exclusion to asynchronous
sealing. Add active-completion and queued-rejection reentrancy regressions proving finite cleanup.

The five round-5 focused regressions pass. Module boundaries and Swift 5/macOS 13 compatibility remain
intact. Signing and embedded-entitlement verification is deferred and is not a finding.

**Unresolved findings: 2**
