# Architecture/API Implementation Review — Round 2

## ARCH2-001 — P1 High: late cancellation can outlive completion cleanup and leak operation IDs

`ViewerStoreExplorerGateway.swift:719` marks an active operation cancelled under the gateway lock,
but releases that lock before registering cancellation with the services. The operation can then
finish and clear cancellation state before the delayed registration inserts the UUID into the SQLite
reader sets. That UUID has no later cleanup path and repeated races can grow process-lifetime state.
`sealAndWait` has the same ordering.

The exact-ID comparison fixes successor interruption, but cancellation registration and final cleanup
must be strictly ordered. Add a deterministic test covering query/catalog and export readers.

**Unresolved findings: 1**
