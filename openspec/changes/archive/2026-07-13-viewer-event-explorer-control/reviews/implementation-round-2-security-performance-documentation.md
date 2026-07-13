# Security, Performance, Privacy, and Documentation Review — Round 2

## SPD-R2-001 — P1: terminal updates can be evicted before projected sessions become reclaimable

When 16 session updates are pending, `sessionStarted` may evict a pending terminal update to admit a
fresh session. That terminal update can be the only signal marking an already-projected session ended.
If 16 projected sessions disconnect while projection is blocked and 16 replacements start, all old
terminal transitions can be replaced. The drain then sees the old projected sessions as active, cannot
reclaim them, and cannot attach metadata to replacements.

Preserve terminal tombstones separately, apply them before new Event/session-start admission, never
evict the only projected-session terminal transition, and add a blocked two-generation 16-session
regression.

**Unresolved findings: 1**
