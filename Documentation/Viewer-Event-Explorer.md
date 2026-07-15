# NearWire Viewer Workspace Guide

## Scope

NearWire presents one current Session for the lifetime of the Viewer process. The Viewer does not
show a Sources sidebar, retain a catalog of previous launches, or reopen an earlier working
Session. A private process-scoped Store supports bounded search, filtering, Event details,
Performance analysis, and export while the process is running.

The main workspace is arranged as follows:

```text
Listener and Session controls
Devices
Event Timeline | Event Inspector (optional)
Viewer -> App composer (optional)
```

The top toolbar has independent Timeline, Inspector, and Composer visibility controls. Each control
uses an icon, a visible selected state, an accessibility value, and a tooltip. Hiding one region
does not destroy the current filter, selection, composer draft, or Device scope. These controls
remain meaningful because the main window is always the Event workspace. The labeled
**Performance** button opens or focuses a separate singleton Performance window.

## Devices and scope

The horizontal Devices strip begins with `All Devices` and then shows the bounded set of connected
or materialized Apps for the current Session. Selecting a Device updates the Event scope and the
target used by Device details. The Viewer can merge one through sixteen selected Device lanes.
Performance analysis uses its own exact-Device picker. On first open it adopts the Event Device only
when exactly one valid Device is selected; later Event filter changes do not retarget a valid
Performance choice. Recently disconnected or otherwise non-analyzable rows remain truthful in the
Device inventory but are not valid Performance choices or fallback candidates.

Pending approvals appear in the same top region so accepting or rejecting an App does not require
a separate source browser. Import, Export, and Device Settings are also available there. Import is
disabled while any App is connected, any admission decision is pending, or another workspace
operation is active.

## Current-Session lifetime

Opening the Viewer creates a unique owner-only working directory under the user's temporary
directory. The directory name contains the process identifier and a random nonce. A private marker
binds exact cleanup to that directory. The runtime closes all SQLite connections before removing
the marked directory at terminal shutdown.

This working Store is an implementation detail, not a saved Source. Events can still be called
`Recorded` inside the current process because the Store, rather than the bounded live projection,
is authoritative for filtering and details. That label does not promise availability after the
Viewer quits.

If storage is temporarily unavailable, the current runtime remains useful through a bounded
in-memory projection. A memory-only row is labeled `Not recorded`; it cannot be exported and is
not later claimed as durable after it leaves the live window.

## Time and ordering

NearWire captures one Viewer wall time and one Viewer monotonic receive time when an Event commits
at the protocol boundary. The live projection and working Store share that observation. Timeline
ordering is `(Viewer receive monotonic time, Store Event row ID)`, so merged Device lanes do not
depend on iPhone wall clocks.

The inspector shows App-created wall time, App-origin monotonic time, and Viewer receive wall time
separately. NearWire does not rewrite one clock as another.

## Clear

`Clear` appears in the Event Timeline toolbar and requires destructive confirmation. It atomically
removes the current Session's Events and Event-derived data, including dispositions, diagnostics,
annotations, and Performance samples. It also clears the matching live projection and invalidates
pre-Clear query, detail, renderer, and Performance results.

Clear preserves:

- the listener and pairing code;
- connected Devices and their negotiated policies;
- the active Session identity;
- Viewer-to-App composer capability.

New Events can arrive immediately after Clear. Clear is serialized with Event commits and import,
so a predecessor operation cannot repopulate the empty workspace after completion.

## Complete-Session import and export

Export writes a schema-versioned JSON document for the complete current Session. The document
contains Session metadata, Device aliases, Events, gaps, annotations, dispositions, and safe
causality metadata. It omits TLS keys, pairing material, session epochs, and transport endpoints.
Export is snapshot-based and uses bounded reads and writes.

The export file is unencrypted and outside Viewer workspace cleanup. `device-N` and
`connection-N` are pseudonyms, not redaction. Session metadata and notes, annotations and
diagnostic gaps, Event metadata and content, and peer-provided App display name, application
identifier, and application version are exported verbatim. App hints remain unauthenticated.
Those fields and the chosen destination can expose secrets or identifying data. The Viewer shows
this disclosure before export.

Import accepts only the supported complete-Session schema. It uses a no-follow, read-only regular
file descriptor, a maximum file size, bounded record counts, bounded JSON depth, and per-record
limits. The Viewer parses and replaces the current Session in one serialized transaction. A
malformed, oversized, unsupported, cancelled, or failed import leaves the prior Session unchanged.

Imported Devices receive new local logical identities, are shown as offline, and cannot acquire a
live route. Repeated aliases within one document keep their relationship without being treated as
trusted installation identifiers. Import does not change the listener, pairing code, Viewer
identity, or approval policy.

## Search, filtering, and pause

The Explorer supports Event type, content, App and Bundle hints, direction, priority, receive-time,
selected Devices, typed JSON paths, gap, drop, and disposition filters. Different dimensions
combine with AND; multiple selected values within one dimension combine with OR. Search and filter
inputs have explicit byte, predicate, and Device-count limits. Invalid or excessive work returns
fixed guidance instead of widening the query.

`Pause` freezes presentation only. Networking, queue admission, current-Session recording, and
Viewer-to-App sending continue. `Resume` starts a fresh bounded snapshot. Manual scrolling turns
off auto-follow, and `Jump to Latest` restores the tail view.

## Timeline stability

Timeline, Inspector, Devices, composer, and header state use separate semantic presentation
signatures. Equivalent high-frequency snapshots are coalesced, data-only row changes have implicit
animation disabled, and row identities remain stable. Selecting a tab or toggling a panel publishes
layout state immediately. An Event arrival does not rebuild unrelated root regions.

The Timeline retains at most 600 Event rows and 128 diagnostic gap markers. Page work uses frozen
keyset cursors and bounded SQLite budgets. An evicted selection is cleared; an unrelated row is
never selected in its place.

## Inspector and renderers

The inspector owns one selected Event. Raw JSON is paged in bounded chunks, Pretty JSON has bounded
input and derived output, and the tree renderer limits visible nodes and expansion width. Built-in
renderers cover log, table, chart, and timeline-shaped Events; incompatible content falls back to
Generic JSON with fixed guidance.

Event detail retrieval is generation-bound. Clear, import, scope change, pause, filter change, or
selection change invalidates predecessor work. A stale result cannot overwrite the current
Inspector.

## Viewer-to-App composer

The composer is memory-only. It supports Event type, JSON content, normal and high priority, and an
optional TTL. Queueing a draft does not create send history. A downlink Event appears in the normal
Timeline only after secure transport admission. The composer never retries silently and never
persists templates, drafts, or a separate command history.

## Accessibility and keyboard behavior

Panel controls expose labels, selected values, and help text without relying on color alone. Clear,
Import, and Export publish truthful disabled states and operation guidance. Standard macOS keyboard
focus order reaches the top controls, Devices, Timeline tools, Inspector, and composer. The layout
supports the maintained 1,000 by 720 point minimum window in light and dark appearances.
