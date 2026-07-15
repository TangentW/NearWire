# viewer-performance-dashboard Specification

## Purpose

Define the singleton native Performance window as a bounded, rebuildable projection of current-Session performance Events for one exact App connection.
## Requirements
### Requirement: Performance projection is a bounded view of current memory Events

The Performance dashboard SHALL select one exact current-Session connection and freeze its bounded memory Event slice before projection. Target identity, cache identity, range bounds, gaps, raw Event locators, cancellation, and successor publication SHALL use runtime, connection, and journal identities only. They SHALL contain no recording row, persistent upper bound, traversal lease, or persistence fallback.

The projection SHALL validate only `nearwire.performance.snapshot` content and SHALL preserve typed availability rather than invent values. Runtime replacement, Device replacement, import, Clear, or window close SHALL invalidate and join predecessor work before a successor owns publication.

#### Scenario: Performance refreshes from current Session

- **WHEN** retained performance Events change for the selected connection
- **THEN** one frozen memory slice produces the successor cards and charts
- **AND** no database query or historical reconciliation is constructed

### Requirement: One exact Device and deterministic ranges preserve clock domains

Performance SHALL maintain its own exact Device selection independently from Event filters. On first open it MAY adopt the Event scope only when exactly one eligible Device is selected; later Event-filter changes SHALL NOT silently retarget a valid Performance choice. Recently disconnected or imported offline rows MAY remain visible but SHALL be disabled when they cannot compile an exact analysis target.

The range picker SHALL provide 1 minute, 5 minutes, 15 minutes, and Session, with 5 minutes as default. Range bounds SHALL be inclusive, use Viewer monotonic receive time for ordering and aggregation, and use Viewer wall time only for display. App-created clocks SHALL remain raw metadata. A requested leading interval outside retained memory SHALL be presented as memory-window coverage loss without interpolation.

#### Scenario: Main Event Device selection changes

- **WHEN** Performance already owns a valid exact Device and the Event workspace changes its filter selection
- **THEN** Performance keeps its Device and range
- **AND** no cross-Device clock or lifecycle is silently merged

### Requirement: Aggregation remains globally bounded and deterministic

One result SHALL contain at most 512 aligned buckets, ten numeric accumulators per bucket, 128 detailed gaps, 128 invalid diagnostics, fixed summaries for the 16-metric inventory, six charts, 12,288 marks, and 64 accessible bucket summaries per chart. Each numeric accumulator SHALL retain finite minimum, maximum, sum, count, first and last Viewer time, nonmeasurement counts, continuity, and one center-nearest contributing journal key. It SHALL NOT retain a complete raw-sample array.

At most four completed exact-key results SHALL be cached under the existing deterministic 16 MiB derived-state ledger; one completed result SHALL remain at most 8 MiB. Eviction SHALL occur before insertion. Limit exhaustion SHALL publish fixed guidance and SHALL NOT expose a partial result as complete.

#### Scenario: A long range contains many samples

- **WHEN** the selected memory slice contains more samples than the bucket count
- **THEN** values reduce into at most 512 aligned buckets with average and min/max envelope
- **AND** raw sample count cannot create unbounded chart state

### Requirement: Availability, freshness, and gaps preserve uncertainty

Present numeric zero, Boolean false, and categorical unknown SHALL remain measured values. Explicit reasons SHALL display Unsupported, Disabled, Permission denied, or Temporarily unavailable. Absence without a matching record SHALL display Not collected; invalid typed content SHALL display Invalid snapshot.

Current cards SHALL use the latest raw performance Event at or before the anchor, looking back at most 180 seconds. Freshness SHALL use the smaller of 180 seconds and the larger of three sample intervals or three seconds; invalid interval data SHALL use three seconds. Equality with the deadline is stale. Imported offline Session values SHALL be evaluated once against their frozen anchor and SHALL NOT compare an old monotonic clock with current Mac uptime.

Applicable App-to-Viewer gaps and unknown gaps SHALL break affected series; Viewer-to-App-only gaps SHALL not. A gap SHALL be placed only when trustworthy evidence maps it to one unique bucket envelope. Invalid, ambiguous, interval-less, hidden, or overflowed applicable evidence SHALL become Unplaced gap and conservatively suppress inter-bucket lines without fabricating values.

#### Scenario: CPU is measured as zero and GPU is unsupported

- **WHEN** one snapshot reports CPU zero and explicit unsupported GPU availability
- **THEN** CPU is shown as measured zero and GPU as Unsupported
- **AND** neither value is replaced by Not collected or a fabricated numeric GPU value

#### Scenario: Applicable gap placement is ambiguous

- **WHEN** a gap cannot map to one unique bucket
- **THEN** the range discloses an Unplaced gap and keeps disconnected points or envelopes
- **AND** the dashboard does not interpolate a guessed position

### Requirement: Projection refresh preserves stable SwiftUI presentation

Initial load, explicit Device or range replacement, empty state, Pause/Resume, and failure SHALL publish their visible states. Once a complete dashboard exists, ordinary refresh start and progress SHALL remain internal and SHALL NOT replace cards or charts with an intermediate loading branch, reset scrolling, recreate containers, or trigger implicit animation. A valid semantically changed successor SHALL publish exactly once; discarded or equivalent work SHALL publish nothing.

Projection and decoding SHALL run off the MainActor under bounded cancellation and work rules. At most one scan plus one dirty successor SHALL run, and current refresh SHALL publish at most once per main run-loop turn and ten times per second. Model changes SHALL not be published from within SwiftUI view updates.

#### Scenario: New performance Event arrives

- **WHEN** cards and charts are already visible
- **THEN** the prior dashboard remains continuously visible during projection
- **AND** only changed values publish without whole-window flashing

### Requirement: Pause and cleanup do not alter protocol capture

Pause SHALL freeze the complete Performance presentation but SHALL NOT pause network receive, memory admission, Session retention, or flow control. While paused, only bounded dirty state SHALL accumulate. Resume SHALL run one fresh projection.

Closing Performance or ending/replacing the runtime SHALL cancel work and clear received metric content, buckets, cache, gaps, invalid details, crosshair, tooltip, deadline receipts, and raw-resolution work. Reopening SHALL reuse the single Viewer runtime and current Session and start a fresh projection.

#### Scenario: Performance window closes

- **WHEN** the operator closes Performance
- **THEN** all derived metric and interaction state owned by that window is cleared
- **AND** no Performance content is persisted locally

### Requirement: Raw Event reveal resolves only exact retained identity

Open Raw Event SHALL resolve the selected metric's representative journal key against the current memory Session at action time. Success SHALL focus the main Viewer, make Inspector visible, and select the exact retained Event. Evicted, stale, or unavailable identity SHALL preserve prior selection and Performance presentation with fixed guidance. Viewer SHALL NOT choose a neighboring Event, copy raw JSON through the Performance model, or use a persistence fallback.

#### Scenario: Raw contributing Event was evicted

- **WHEN** Open Raw Event resolves a journal key no longer retained in memory
- **THEN** the prior Event selection and Performance presentation remain unchanged with fixed guidance
- **AND** no database fallback or nearby Event is selected

### Requirement: Performance UI is accessible, private, and localized

The singleton native macOS window SHALL expose an accessible exact-Device picker, scalable current cards, fixed 16-key availability section, six bounded Charts views, synchronized pointer and keyboard crosshair, aggregate tooltip, raw Event action, and Show Viewer action. State SHALL not rely on color. Controls and Viewer-owned presentation SHALL be complete in English and Simplified Chinese; received App values SHALL remain verbatim.

Received values and derived content SHALL have no log, analytics, clipboard, drag, share, preference, restoration, recent-row, export, or content-bearing reflection sink. Stable group and metric identity SHALL survive ordinary refresh, and data changes SHALL disable implicit animation without disabling interaction.

#### Scenario: Viewer language changes while Performance is open

- **WHEN** the operator changes the supported Viewer language
- **THEN** labels, guidance, accessibility text, and formatting update immediately
- **AND** Device choice, range, charts, and Session content remain unchanged
