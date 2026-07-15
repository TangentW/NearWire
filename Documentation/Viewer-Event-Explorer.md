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

Opening the Viewer starts an empty memory Session. The production runtime creates no Source or
Session database and performs no database recovery, retention, or cleanup. The workspace describes
this lifetime once at the Session level rather than repeating an `In memory` badge on every Event.
The normal `consumerAccepted` pipeline state is likewise omitted from Timeline rows; Event detail
can still expose it as technical metadata. Closing the process clears received Session content.

The memory window retains at most 512 Events, 32 MiB of accounted Event data, and 16 Device-session
metadata lanes. Older content can be evicted as newer Events arrive. Export contains only the
snapshot still retained at the moment the operator starts the export.

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
off auto-follow, and `Jump to Latest` restores the tail view.

## Timeline stability

Timeline, Inspector, Devices, composer, and header state use separate semantic presentation
signatures. Equivalent high-frequency snapshots are coalesced, data-only row changes have implicit
animation disabled, and row identities remain stable. Selecting a tab or toggling a panel publishes
layout state immediately. An Event arrival does not rebuild unrelated root regions.

The Timeline is derived from the 512-Event memory window and bounded diagnostic markers. An evicted
selection is cleared; an unrelated row is never selected in its place.

Each Timeline row leads with a single-line compact JSON content preview. The preview reads at most
256 UTF-8 bytes and ends with an ellipsis when truncated, so large Event payloads are not repeatedly
converted for display. Event type appears in the secondary metadata line without headline emphasis.

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
