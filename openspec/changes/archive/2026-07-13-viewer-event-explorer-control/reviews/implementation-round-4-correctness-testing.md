# Correctness and Testing Implementation Review — Round 4

## CT-R4-001 — P1 High: inferred direct mode can retain stale sessions at lifecycle transition

`laterDisposition` changes the projection into lifecycle-managed mode even though it is not a session
lifecycle callback. Conversely, when the first real session lifecycle callback arrives, direct-only
sessions and Events are not retired against the manager's authoritative active-session set. A caller
that observes direct Events, applies a later disposition, and later begins manager-driven lifecycle
delivery can therefore either change modes too early or retain stale direct sessions that consume the
bounded live window.

Switch modes only on an actual session lifecycle callback. Make that first transition atomic with
reconciliation against the authoritative active-session snapshot, and add a regression that applies a
later disposition in direct mode before starting a lifecycle-managed session.

No other correctness or test-coverage finding was identified.

**Unresolved findings: 1**
