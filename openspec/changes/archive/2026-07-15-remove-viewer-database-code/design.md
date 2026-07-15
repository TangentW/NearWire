# Context

The production runtime already treats `ViewerLiveEventWindow` as the final Session authority, but most controller contracts were originally shaped around an optional Store. Empty gateways and compatibility branches still carry database types through Event, Performance, import/export, and test code. The Xcode target also still links `libsqlite3`, compiles a SQLite bridging header, and includes every former Store source.

# Goals and Non-Goals

Goals:

- Remove all Viewer SQL statements, table/schema definitions, SQLite operations, database lifecycle code, database source files, and database-only tests.
- Make memory ownership visible in type names and controller composition instead of representing memory as a special Store mode.
- Preserve bounded current-Session product behavior and the useful in-memory Renderer tab.
- Remove the causality UI and code that cannot function without durable cross-Event lookup.

Non-goals:

- Change transport, pairing, TLS, SDK APIs, Event payload limits, flow control, or Event wire semantics.
- Add another persistence engine, server, historical Session feature, or cross-process cache.
- Redesign the Renderer formats or add new renderer plug-ins.

# Decisions

## Delete the Store as one architectural unit

The complete `Viewer/NearWireViewer/Store` implementation is removed, together with `libsqlite3`, the Objective-C bridging header setting, and `ViewerStoreTests.swift`. Pure JSON Session document parsing currently colocated with Store export is moved into an Application-owned memory transfer file. Small value types that remain meaningful without persistence are either moved or renamed; SQL/query/lease/catalog/schema/maintenance types are not preserved as compatibility shims.

Source scans after deletion reject `import SQLite3`, SQLite symbols, SQL schema statements, and Xcode SQLite linkage under Viewer production and test paths. Legacy archived OpenSpec artifacts may retain historical text, but active specifications and maintained documentation describe only the memory Session.

## Event exploration is a bounded memory evaluation

The Event controller owns one current source, a selected logical-Device set, one closed filter draft, the bounded Timeline result, selected Event detail, renderer preparation, Clear, and complete-Session JSON transfer. It no longer owns recording/device catalogs, Store row IDs, Store traversal leases, database pagination, recording mutation, filtered durable export, or Store rematerialization.

The existing bounded live evaluator and stable journal identity remain. Any remaining type named `Stored`, `Durable`, or `Store` is reviewed: it is renamed when the concept is only a database artifact, or retained only when it describes a protocol outcome independent of persistence.

## Performance reads frozen memory slices directly

Performance targets use runtime logical ID plus connection ID. Projection preparation freezes one memory snapshot and never constructs database bounds, row IDs, Store identities, or Store traversal receipts. Raw Event reveal resolves the contributing journal key against the current memory window.

## Remove Causality, retain Renderer

The Causality tab previously followed `correlationID` and `replyTo` through bounded database candidate queries. In memory-only production it always reported unavailable for current Events, so the tab, state machine, gateway operation, graph models, localized copy, and tests are deleted.

The Renderer tab is retained. It operates only on the already-selected canonical Event bytes and provides bounded specialized views for `log.*`, `table.*`, `chart.*`, and `timeline.*`, with Generic JSON fallback. It creates no history, database, or secondary Session authority.

## Verification stays proportional

The final gate builds the Viewer with Swift 5 mode and Strict Concurrency, runs focused current-Session Event/Renderer/Performance/transfer tests plus the remaining Viewer suite, scans maintained Viewer paths for database implementation residue, and uses three independent review agents for architecture/API, correctness/testing, and security/performance/documentation. Review excludes archived OpenSpec history and unrelated project files.

# Risks and Mitigations

- Removing a large compatibility surface can expose hidden type dependencies. Compile in small layers and move only contracts proven necessary by the memory runtime.
- Deleting database tests can accidentally delete useful protocol or memory tests. Preserve tests whose subject remains active, relocating them into Foundation or FlowControl suites when needed.
- Large source deletion can mask project-file mistakes. Verify the Xcode target has no missing references, bridging header, or SQLite framework and performs a clean build-for-testing.
- Renderer preparation handles received content. Preserve existing byte, time, derived-output, cancellation, accessibility, and redacted-reflection bounds.
