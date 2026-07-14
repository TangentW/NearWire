# Raise the Event Content Limit to 1 MiB

## Why

NearWire currently rejects Event content above 256 KiB. Internal users need to send larger JSON
documents without adding attachment or streaming APIs yet. Raising only one public or queue
constant would be incomplete: the validated JSON model, offline queue accounting, deterministic
wire record, Event frame, Viewer admission, and transport capacities must all agree on the same
fixed content boundary.

## What Changes

- Raise the default deterministic JSON Event-content limit from 256 KiB to exactly 1 MiB
  (1,048,576 bytes).
- Preserve dynamic encoding: Events use their actual encoded byte length and are never padded to
  the maximum.
- Increase the derived internal model, queue, Event-frame, session, and transport capacities only
  as needed to carry one maximum-content Event plus existing protocol overhead.
- Keep the existing 16 MiB wire hard ceiling, bounded queue eviction, decoder preflight, and
  conservative peer negotiation.
- Update boundary tests and user-facing documentation so 1 MiB has one unambiguous meaning.

## Non-Goals

- No runtime or Viewer-configurable content limit.
- No fragmentation, compression, attachments, file transfer, or streaming payload API.
- No change to Event frequency limits, Bonjour, TLS, pairing, persistence retention, or UI layout.

## Impact

- Affected capabilities: `event-model`, `bounded-event-queue`, `sdk-offline-buffer`,
  `sdk-active-event-pump`, `wire-event-transfer`, `wire-framing`, and
  `viewer-application-foundation`.
- Affected implementation: Core Event validation and defaults, SDK buffer defaults and boundary
  tests, shared wire defaults, Viewer admission/session construction, README/API documentation,
  and packaging/build evidence.
- Public API shape remains source compatible. Default buffer byte capacities increase to retain a
  worst-case validated 1 MiB content model safely.
