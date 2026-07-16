# Self-Review

The final change was reviewed for:

- exact grouping by the existing installation identity plus optional application identifier;
- a stable in-process SwiftUI identity derived from the bounded logical-route key;
- representative connection selection preferring current runtime state, then active memory state,
  then the most recently ended retained connection;
- imported rows never merging with live routes and different App routes remaining distinct;
- connection-scoped Event, Performance, details, selection, control, and transport APIs continuing
  to receive the representative connection UUID rather than the presentation UUID;
- focused Device state surviving reconnect because the Device card identity remains stable;
- warning and materialized indicators aggregating across hidden predecessor rows;
- no persistence, logging, analytics, clipboard, export, or protocol use of the presentation UUID;
- bounded input and negligible deterministic 128-bit identity collision risk.

No unresolved issue remains after focused reconnect tests, both relevant Viewer test classes,
Viewer build, strict OpenSpec validation, and diff checks.
