# Design

## Logical presentation identity

Live Device rows use the same unauthenticated route tuple already used by session ownership:
installation identity plus optional application identifier. A deterministic UUID derived from the
bounded route storage key is used only as the SwiftUI presentation identity. The current connection
UUID remains a separate field and continues to drive Event scope, Performance targeting, details,
and control behavior.

Imported Device rows retain their connection UUID as presentation identity and are never merged
with live routes.

## Candidate reduction

The Explorer combines memory-Session connection metadata with current runtime snapshots, groups
non-imported candidates by logical route, and chooses one representative:

1. the current non-recent runtime snapshot;
2. an active memory-Session connection;
3. the most recently ended retained connection;
4. a deterministic connection-UUID tie-break.

Group warning and materialization indicators are combined so hiding predecessor cards does not hide
known exceptional state. The chosen row retains its current connection UUID for existing actions.

## Verification

- Reconnect the exact same route multiple times and assert one stable Device row remains.
- Assert the row changes its representative connection to the newest current connection.
- Assert a different installation/application route and imported rows remain distinct.
- Run focused flow-control tests, Viewer tests, build, and self-review.
