# Correctness/Test Review — Round 2

## CT-R2-001 — P2: late exact cancellation leaks operation IDs indefinitely

The gateway releases its lock after accepting cancellation but before registering the UUID with
SQLite. Completion can clear the UUID first, after which delayed registration leaves it retained
without a later cleanup path. Serialize registration with completion or add an explicit registration
phase, and test the completion-boundary interleaving deterministically.

The tombstone binding, successor/pre-active cancellation, live checkpoint cancellation, session churn,
precomputed wire bytes, and latest-only preparation paths were otherwise correctly remediated in the
inspected paths.

**Unresolved findings: 1**
