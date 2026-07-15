## 1. Planning Gate

- [x] 1.1 Complete proposal, design, capability deltas, and this task plan.
- [x] 1.2 Strictly validate the active OpenSpec change before source modification.

## 2. Memory-Only Source Architecture

- [x] 2.1 Move required memory Event, JSON transfer, filter, operation, and Performance contracts out of Store sources and remove database-derived compatibility branches.
- [x] 2.2 Simplify Event exploration, detail selection, Clear/import/export, and Performance projection/raw reveal to memory-only paths.
- [x] 2.3 Remove the Causality Inspector surface and keep the bounded in-memory Renderer surface.

## 3. Delete Database Implementation

- [x] 3.1 Remove Store/SQLite source files, SQL/schema code, bridging header, libsqlite3 linkage, and Xcode Store groups/build entries.
- [x] 3.2 Delete database-only tests and preserve only tests for still-supported memory, protocol, UI, transfer, Performance, and Renderer behavior.
- [x] 3.3 Remove or rewrite maintained database documentation, active spec references, and localized strings that describe deleted behavior.

## 4. Validation and Review

- [x] 4.1 Build the Viewer and run focused plus remaining Viewer tests with exact evidence recorded.
- [x] 4.2 Run maintained-path scans proving no Viewer database code, SQL schema, SQLite import/linkage, or database test remains.
- [x] 4.3 Run architecture/API, correctness/testing, and security/performance/documentation reviews; fix actionable findings and repeat a focused clean round.
- [x] 4.4 Complete the spec-to-evidence audit, strictly validate, and archive the change.
