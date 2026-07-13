# Architecture/API Implementation Review — Round 3

## ARCH3-001 — P1 High: blocked projection can discard the newest active session

The pending lifecycle buffers independently retain the first 16 distinct starts and terminations.
Later transitions are dropped. With projection blocked across more than 16 connection generations,
obsolete intermediate generations can occupy both maps while the final active generation loses its
metadata. Deferred terminations also run only after all Event admission, so stale sessions can consume
capacity before the newest generation is materialized.

Replace the pending maps with one bounded authoritative state machine that preserves the current
active connection set, prioritizes terminal state for projected sessions, and drains lifecycle state
causally. Add a blocked churn regression spanning more than 16 generations and prove the final active
generation and its metadata/Event survive.

Cancellation registration ordering was verified as sound and free of an inverse-lock or production
callback deadlock in the reviewed paths.

**Unresolved findings: 1**
