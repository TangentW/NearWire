## Why

Timeline rows briefly expose the normal `buffered` admission state before an Event advances to its accepted state, creating a distracting badge flash. The Performance window also derives chart points repeatedly inside SwiftUI rendering, including a backward continuity scan for every point, while an isolated sample has no visible line or envelope. This can leave charts apparently empty and makes live updates unnecessarily expensive.

## What Changes

- Hide normal transient Event admission dispositions from Timeline rows while retaining exceptional diagnostic states.
- Prepare immutable Performance chart point collections as part of the off-main projection instead of rebuilding and rescanning them from SwiftUI body evaluation.
- Bound dashboard rendering to a practical maximum of 120 aligned buckets while preserving minimum, average, maximum, gaps, and the existing global safety ceilings.
- Render an explicit point for every measured chart bucket so a single sample remains visible.
- Iterate only prepared measured points in chart views and preserve stable chart and metric identities during ordinary refresh.

## Capabilities

### Modified Capabilities

- `viewer-event-explorer-control`: classify normal admission pipeline states as non-diagnostic Timeline metadata.
- `viewer-performance-dashboard`: prepare bounded chart geometry off the MainActor and guarantee visible isolated samples with stable, efficient refresh.

## Impact

This change affects only macOS Viewer Timeline presentation, Performance aggregation/presentation, and focused Viewer tests. It does not change Event bytes, admission semantics, SDK APIs, transport, Session retention, Performance metric schemas, range choices, or persistence.
