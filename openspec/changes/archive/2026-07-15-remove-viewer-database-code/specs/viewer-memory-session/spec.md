## MODIFIED Requirements

### Requirement: Viewer retains one bounded memory-only current Session

The production Viewer SHALL use one process-lifetime in-memory current Session as the only authority for received Event presentation, detail, filtering, diagnostics, and Performance input. It SHALL retain at most 512 Events, 32 MiB of accounted Event data, and 16 Device-session metadata lanes, with the existing bounded ingress. It SHALL NOT create, open, query, recover, clean, or close a SQLite database or another local persistence engine for Sources or Sessions. A later process SHALL start empty unless the operator explicitly imports a supported JSON file.

The maintained Viewer production and test targets SHALL contain no SQLite linkage or import, Objective-C SQLite bridge, SQL statement, schema/table definition, database connection or transaction wrapper, Store catalog/gateway/lease/maintenance/recovery implementation, storage preference for Session data, or database-only test. Former database files SHALL be deleted rather than retained as unreachable compatibility code. Pure JSON Session transfer and closed filter validation MAY remain only in memory-focused files without database APIs.

Oldest-Event eviction SHALL preserve newer Event progress and expose one bounded in-memory-window gap. Shutdown, identity reset, listener failure cleanup, or runtime replacement SHALL clear all received Event content and derived Performance values.

#### Scenario: Maintained Viewer sources are scanned

- **WHEN** production, test, and Xcode project paths are scanned after cleanup
- **THEN** they contain no SQLite import/link, SQL schema or table statement, database source group, or database-only test suite
- **AND** archived OpenSpec history is excluded from the maintained-code scan

#### Scenario: Viewer receives Events during one launch

- **WHEN** Apps send Events within the memory bounds
- **THEN** Timeline, Inspector, filters, Renderer, and Performance consume the same in-memory Session snapshot
- **AND** no database compatibility gateway, catalog request, or lifecycle work is constructed

#### Scenario: The memory window reaches its bound

- **WHEN** another accepted Event would exceed retained count or accounted bytes
- **THEN** the oldest retained Events are evicted within the fixed bound and a bounded gap is shown
- **AND** the connection and newer Event admission continue

#### Scenario: Viewer launches again

- **WHEN** a new Viewer process starts after a prior process ended or crashed
- **THEN** it starts with an empty current Session
- **AND** no prior Source or Session is recovered automatically
