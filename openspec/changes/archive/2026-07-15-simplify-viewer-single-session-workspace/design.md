## Context

The current Explorer models both a live runtime and an unbounded sequence of historical recording Sources. The UI materializes that model in a permanent leading sidebar. Internally, SQLite remains valuable for bounded pagination, filtering, detail, export, and Performance projection, so removing historical Sources does not justify replacing the Store with an unbounded in-memory Event array.

The root view observes a broad application object, and both Timeline and Inspector observe one broad Explorer controller revision. Session counters and Event refreshes can therefore recompute unrelated split-view regions. SwiftUI may preserve semantic values while still rebuilding enough layout to produce visible movement.

## Goals and Non-Goals

Goals:

- Present one current working Session and Devices at the top of the Viewer.
- Keep all current-session queries bounded while retaining no cross-launch recording browser.
- Support explicit Session save/load through JSON without treating imported peer data as trust or identity.
- Clear current Event history safely while connections continue.
- Give operators direct, accessible control over the three major workspace regions.
- Make high-frequency Event updates local to Timeline and Performance presentation.

Non-goals:

- Change App/Viewer transport, pairing, flow control, or connection limits.
- Persist panel visibility or imported content between Viewer launches.
- Merge an imported Session with a live Session.
- Import legacy arbitrary JSON, partial filtered exports, foreign schema versions, security identity, device capabilities, or connection state.
- Replace the native split-view interaction with a custom layout engine.

## Decisions

### One working Session is process-scoped, not an in-memory Event bag

The live application creates a unique working Store directory for the Viewer process. SQLite remains the authoritative bounded query engine, but the directory is not offered as historical Viewer state on another launch. Terminal cleanup closes SQLite and makes bounded attempts to remove the exact marked directory; a timeout, permanent removal failure, or interrupted process may leave that temporary directory behind, and no later launch catalogs or reopens it. Any best-effort scavenging may remove only directories carrying NearWire's exact workspace marker and never follows symbolic links.

The Store still has one internal recording row because existing pagination, materialization, and export invariants require a positive recording key. That row is an implementation detail. The application and Explorer expose only `Current Session`; historical recording catalog selection, recording metadata editing, pinning, retention settings, and history cleanup UI are removed.

### Devices become a stable horizontal strip

A Devices strip sits below the pairing/listener header and above Analysis. It exposes All Devices, bounded device chips, the selected Device settings action, and pending approvals. Chips show connection state without Event content. The strip scrolls horizontally rather than increasing window height when many Devices are present.

Device scope remains multi-select for Events and single-device for Performance. The existing selected route continues to own the Device details sheet; selecting a Device chip both updates Event scope and makes that Device the details target.

### Clear is a generation replacement, not presentation-only deletion

Clear requires an explicit destructive confirmation and remains available while Apps are connected. The shared mutation gate drains already admitted live decisions into the Store's serialized preparation prefix, invalidates existing query/export leases, deletes current recording Event rows and their dependent disposition/full-text rows plus gap/drop/annotation rows in one transaction, and advances the Store generation/change token. Device-session rows, active network sessions, rate policy, and listener state remain.

The live projection receives the same clear generation and removes pre-clear Event and diagnostic observations before the Explorer rematerializes. Any pre-clear page, detail, renderer, Performance, or export completion is stale and cannot repopulate the workspace. Events committed after the clear boundary remain visible.

### Import atomically replaces an inactive working Session

Import is enabled only when no Device connection is active or disconnecting and no admission is pending. Viewer acquires one authoritative admission/session mutation lease before presenting the destructive disclosure or open panel and holds it through picker cancellation, validation, rollback, or commit. Import accepts only a complete NearWire JSON export with the supported schema version; a filtered export is rejected because it cannot represent a Session.

The importer opens a regular non-symbolic-link file, uses mapped read-only bytes plus a cancellation-aware structural scanner to decode one bounded JSON value at a time, enforces file/record/string/Event limits before allocation, validates cross-references, and stages into a transaction. Cancellation reaches the SQLite bulk replacement through its progress handler. Peer Event UUIDs remain non-unique content; SQLite enforces the canonical Device/direction/wire-sequence key without retaining a document-sized heap set. Imported device aliases are display pseudonyms only. The importer generates new local runtime/device identities and does not restore installation IDs, TLS state, capabilities, connection IDs, queue state, or delivery claims.

Commit clears the current working data and installs the staged Session as one atomic Store mutation. Failure or cancellation changes nothing. A later App connection starts a new live Device lane in the same working Session; import itself never claims a connected Device.

Export keeps the existing unencrypted JSON disclosure and always exports the complete current Session for transfer. Producer and importer share exact bounds of 4,096 Devices, 2,000,000 Events, 500,000 gaps, 100,000 annotations, and a 4 GiB file. Transactional SQLite counters enforce retained Event/gap/annotation bounds in constant time. Over-limit ingress entries are rejected and released instead of retried, preserving later Clear/import progress. Export applies its file budget incrementally and fails atomically before destination replacement if a frozen snapshot or streamed file exceeds a transfer bound. Filtered-result export is removed from the primary single-Session UI but the bounded internal service remains available to existing tests and compatibility code.

The retained counters are schema version 3. Fresh and schema-version-1 Stores create the indexes and counters directly; a valid baseline schema-version-2 Store initializes counters from durable row counts and installs their triggers in one cancellable transaction before normal connections open. Coordinator gap allocation separately restores its next sequence from the durable maximum whenever the current recording is resumed, and an imported Session advances beyond its sequential imported gaps.

### Top controls own panel visibility

Three icon buttons in the top connection header use familiar SF Symbols and selected states for Timeline, Inspector, and Composer. Each has a visible tooltip, accessibility label, keyboard focus, and state-independent meaning. The controls do not use color as their only state cue.

In Events mode, Timeline and Inspector may be independently hidden. If both are hidden, Analysis shows a compact explanation with controls still available above. Performance mode occupies the analysis area and temporarily disables the Event-only panel buttons without changing their stored in-process choices. Composer visibility applies in both modes. Hiding a panel changes only presentation; it does not pause capture, query state, selection, or composer draft.

### SwiftUI invalidation follows semantic regions

The layout retains stable container identity and switches content inside fixed Analysis and composer hosts. Region-specific observable adapters derive compact Equatable Timeline, Inspector, Devices, and header signatures from controller/application publication. They publish only when their own visible signature changes. Timeline rows retain stable Event identity and data-only updates run in a transaction with animation disabled.

The existing maximum ten-refreshes-per-second cadence remains the upper UI data rate. Coalescers suppress equivalent snapshots, and the UI does not reconstruct split-view containers for counter-only session updates. Tests count body-signature publication and verify that Timeline arrival does not publish Inspector or composer layout changes when their visible state is unchanged.

## Risks and Mitigations

- Clear could race admitted or deferred Events. The mutation gate drains deferred decisions and the Store defines one serialized preparation boundary; pre-boundary Events are removed and post-boundary Events remain.
- Clear could leave stale live rows. The live projection receives the same generation invalidation before successor presentation is admitted.
- Import could allocate attacker-controlled JSON. The importer structurally scans mapped bytes, validates lengths before decoding, caps each object, never materializes the entire document graph, and interrupts bulk SQLite work after cancellation.
- Export could produce a file the importer rejects or exhaust the destination volume first. Shared producer/importer constants gate frozen counts, every complete-export write, and final file size before atomic destination replacement.
- Retained-count exhaustion could livelock ingress. Constant-time transactional counters reject and release the offending bounded entry or batch, allowing flush and Clear to continue.
- Recovered or imported coordinator gaps could collide with an in-memory sequence reset. Recording resume reads the durable maximum, import advances past imported rows, and Clear resets only after deleting all gaps.
- Terminal cleanup could block exit forever. Application termination waits for at most one second; the retained cleanup owner uses finite retries and an interrupted marked workspace is never reopened as history.
- Import could forge Device identity. Imported aliases are explicitly offline pseudonyms and never become transport identity, control capability, or reconnection correlation.
- Import during a connection could interleave writes. UI and Store admission both reject import while active/pending Devices exist.
- Collapsing views could cancel useful work. Visibility is view-only state; controllers remain alive and retain bounded state.
- Region signatures could suppress a required redraw. Signatures include every visible state category and focused tests mutate each category independently.

## Verification

- Store tests cover process-scoped paths, exact cleanup, Clear transaction boundaries, live-generation invalidation, import validation, cancellation, rollback, and export/import round trip.
- Controller tests cover one current scope, Clear confirmation and stale completion rejection, imported rematerialization, and Performance reset.
- SwiftUI tests render Devices, every panel visibility combination, empty analysis guidance, and high-frequency Event updates with stable Inspector/composer signatures.
- Full Viewer tests, strict-concurrency build, application build, Demo build, and strict OpenSpec validation run with exact evidence.
- A launched Viewer is visually inspected at minimum, standard, and wide window sizes in light and dark appearances.
