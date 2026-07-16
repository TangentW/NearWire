# NearWire Viewer Workspace Guide

## Scope

NearWire presents one current Session for the lifetime of the Viewer process. The Viewer does not
show a Sources sidebar, retain a catalog of previous launches, or reopen an earlier Session. One
bounded in-memory projection supports search, filtering, Event details, Performance analysis, and
export while the process is running.

The main workspace is arranged as follows:

```text
Listener and Session controls
Devices
Event Timeline | Event Inspector (optional)
Viewer -> App composer (optional)
```

When Timeline and Inspector first appear together, the native horizontal split gives Timeline
approximately 70% of the available width and Inspector approximately 30%. The divider stays at that
initial position through ordinary content updates, remains freely adjustable, and a single visible
Event panel expands into the available width without recreating the surviving panel.

The top toolbar has independent Timeline, Inspector, and Composer visibility controls. Each control
uses an icon, a visible selected state, an accessibility value, and a tooltip. Hiding one region
does not destroy the current filter, selection, composer draft, or Device scope. These controls
remain meaningful because the main window is always the Event workspace. The labeled
**Performance** button opens or focuses a separate singleton Performance window.

Composer starts collapsed so Event analysis receives the full vertical workspace. When shown, it
uses a fixed 240-point region that presents the complete maintained horizontal send form. There is
no draggable vertical divider, so the Composer cannot be resized into a clipped state. Validation
feedback uses the flexible input area, while send state and per-target results use a bounded
internal scroll region instead of increasing the Composer height.

## Devices and scope

The horizontal Devices strip begins with `All Devices` and then shows the bounded set of connected
or materialized Apps for the current Session. Selecting a Device updates the Event scope and the
target used by Device details. The Viewer can merge one through sixteen selected Device lanes.
Repeated connections for the same live installation and application route reuse one Device card;
the card keeps a stable process-local presentation identity and points at the newest current
connection. Retained predecessor Events remain connection-scoped in the memory Session, while
different App routes and imported Devices remain separate cards.
Performance analysis uses its own exact-Device picker. On first open it adopts the Event Device only
when exactly one valid Device is selected; later Event filter changes do not retarget a valid
Performance choice. Recently disconnected or otherwise non-analyzable rows remain truthful in the
Device inventory but are not valid Performance choices or fallback candidates.

Pending approvals appear in the same top region so accepting or rejecting an App does not require
a separate source browser. Import, Export, and Device Settings are also available there. Import is
disabled while any App is connected, any admission decision is pending, or another workspace
operation is active.

## Current-Session lifetime

Opening the Viewer starts an empty memory Session. The production runtime creates no Source or
Session database and performs no database recovery, retention, or cleanup. The workspace describes
this lifetime once at the Session level rather than repeating an `In memory` badge on every Event.
The normal `consumerAccepted` pipeline state is likewise omitted from Timeline rows; Event detail
can still expose it as technical metadata. Closing the process clears received Session content.

The memory window retains at most 32 MiB of accounted Event data and 16 Device-session metadata
lanes. It has no independent fixed Event-count or Timeline row limit, so small Events can remain
visible beyond the former 512-row ceiling. Older content is evicted only when the byte budget is
needed by newer Events. Export contains only the snapshot still retained at the moment the
operator starts the export.

## Time and ordering

NearWire captures one Viewer wall time and one Viewer monotonic receive time when an Event commits
at the protocol boundary. Timeline ordering uses Viewer receive monotonic time plus the stable
Event journal key, so merged Device lanes do not depend on iPhone wall clocks.

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
contains Session timing and state, Device aliases, Events, diagnostic gaps, dispositions, and the
exact correlation/reply metadata carried by Events. It omits TLS keys, pairing material, session
epochs, and transport endpoints.
Export is snapshot-based and uses bounded reads and writes.

The export file is unencrypted and outside Viewer workspace cleanup. `device-N` and
`connection-N` are pseudonyms, not redaction. Diagnostic gaps, Event metadata and content, and
peer-provided App display name, application identifier, and application version are included. App
hints remain unauthenticated. Legacy Session name, note, pin, and annotation fields may be accepted
for format compatibility, but the memory-only Viewer does not materialize or re-export them. The
included fields and chosen destination can expose secrets or identifying data. The Viewer shows
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

`Pause` freezes presentation only. Networking, queue admission, current-Session retention, and
Viewer-to-App sending continue. `Resume` starts a fresh bounded snapshot. Manual scrolling turns
off auto-follow from the actual scroll viewport before a successor Event is published. New content
cannot turn it back on or move the reading position. Returning to the bottom or using
`Jump to Latest` restores the tail view. If a new Event arrives while the Timeline is still
decelerating after a released scroll gesture, NearWire stops the remaining Timeline momentum at
the current visible origin. Other scroll views and the next ordinary gesture remain unaffected.

## Timeline stability

Timeline, Inspector, Devices, composer, and header state use separate semantic presentation
signatures. Equivalent high-frequency snapshots are coalesced, data-only row changes have implicit
animation disabled, and row identities remain stable. Selecting a tab or toggling a panel publishes
layout state immediately. An Event arrival does not rebuild unrelated root regions.

The Timeline is derived from the complete byte-bounded memory window and bounded diagnostic
markers; it does not apply another row-count suffix. An evicted selection is cleared, and an
unrelated row is never selected in its place.

Each Timeline row places Event type, exceptional status badges, and Viewer receive time on one
compact top line. A content summary derived from at most 256 UTF-8 bytes appears below it, wraps to
at most three lines, and tail-truncates any remainder. Device/source, direction, priority, payload
size, and normal acceptance state remain available in Inspector metadata instead of being repeated
on every row.

## Inspector and renderers

The inspector owns one selected Event and exposes Metadata, Raw, Pretty, and Preview. Raw JSON is
paged in bounded chunks, while Pretty JSON has bounded input and derived output. Preview retains
the built-in log, table, chart, and timeline presentations; ordinary or incompatible content falls
back to bounded formatted JSON or the first bounded Raw chunk. Tree and cross-Event Causality views
are not part of the memory-only Inspector.

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
