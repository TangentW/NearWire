## REMOVED Requirements

### Requirement: Viewer owns one local SQLite store with explicit schema and failure boundaries

**Reason**: The production Viewer now uses the bounded memory Session defined by `viewer-memory-session` and opens no local Session database.

### Requirement: Validated bidirectional Event outcomes are journaled without becoming protocol authority

**Reason**: Validated Event outcomes remain bounded in the memory Session; there is no durable journal.

### Requirement: Store ingress and write transactions are finite and nonblocking

**Reason**: Database ingress and transactions are no longer part of the production Viewer path; the existing live ingress bounds remain authoritative.

### Requirement: Storage preferences have bounded 3 GiB and seven-day defaults

**Reason**: A memory-only Session has no database capacity or retention preference.

### Requirement: Cleanup is transactional, whole-session, and protection aware

**Reason**: There is no retained database history to clean up.

### Requirement: Pin, metadata, and manual deletion operations are revision safe

**Reason**: The Viewer no longer exposes stored recordings or historical recording metadata.

### Requirement: Full-text and JSON path queries are validated and indexed

**Reason**: Current-Session filtering is evaluated against the bounded memory snapshot and uses no database index.

### Requirement: Event results use stable bounded keyset pagination

**Reason**: The complete bounded memory window is evaluated as one snapshot and does not use durable pagination leases.

### Requirement: JSON export streams a complete session or frozen filtered result

**Reason**: Export now freezes and writes the retained memory Session as defined by `viewer-memory-session`; filtered durable export is removed from the product path.

### Requirement: Storage status and settings expose no Event data

**Reason**: No production storage status or settings remain.

### Requirement: Shutdown performs a finite owned flush

**Reason**: Shutdown clears bounded memory and joins runtime work; it has no Store flush or database close.

### Requirement: Store exposes bounded explorer catalogs, diagnostics, detail, and mutation facades

**Reason**: Explorer consumes the bounded memory Session directly and exposes no historical catalogs.

### Requirement: Store exposes bounded candidate-scanned performance and gap traversal

**Reason**: Current-Session Performance consumes a frozen memory slice directly.

### Requirement: Viewer automatically records one working-Session lifecycle

**Reason**: The process-lifetime Session is retained in memory and is not recorded.

### Requirement: Current Session Clear is atomic and generation safe

**Reason**: Clear is redefined as a serialized memory-snapshot replacement in `viewer-memory-session`.

### Requirement: Session JSON transfer is bounded, explicit, and atomic

**Reason**: JSON transfer is redefined against the bounded memory Session in `viewer-memory-session`.

## ADDED Requirements

### Requirement: Production Viewer has no local Session Store

The production Viewer SHALL NOT create, open, recover, query, maintain, or remove a local Session or Source database. Current-Session Event search, filtering, details, diagnostics, Performance analysis, Clear, and explicit JSON transfer SHALL operate on the bounded memory Session. No Store catalog, storage preference, retention task, database status, or database recovery lifecycle SHALL run during memory-mode startup or refresh.

#### Scenario: Viewer starts in memory mode

- **WHEN** the production Viewer starts its process-lifetime Session
- **THEN** it initializes the bounded memory workspace without requesting a Store catalog or opening a database
- **AND** Event and Performance presentation remain available from the memory snapshot
