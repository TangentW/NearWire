# Correctness and Testing Implementation Review — Round 3

## CT-R3-001 — P1 High: the replacement generation can lose its disconnects

When 16 projected sessions end while projection is blocked, they fill the termination map. If 16
replacement sessions start and also end before drain, every replacement termination is discarded.
The drain admits those replacements as permanently active, after which later active sessions cannot
obtain session capacity. Existing regressions leave replacements active or begin from an empty
projection and therefore do not exercise this schedule.

Preserve terminal transitions for resident projection identities while keeping ingress bounded. Add
a blocked old-ended, replacement-started-and-ended, fresh-active-generation regression proving no
stale replacement survives and the fresh generation is admitted.

The cancellation completion-boundary implementation and deterministic query/export reader-count
regression were verified as sound.

**Unresolved findings: 1**
