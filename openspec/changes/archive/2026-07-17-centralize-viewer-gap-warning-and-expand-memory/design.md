# Design

## Gap ownership

`ViewerLiveGapSnapshot` remains the Session-wide diagnostic authority. Ingress overflow,
retention-window eviction, and unplaced diagnostic loss remain cumulative until Clear or Session
replacement, but they are no longer copied into every `ViewerLiveEventSnapshot.hasGap` value.

An Event snapshot may retain event-specific gap state only when its exact journal identity has a
presentation conflict. The existing explicit Conflict presentation remains authoritative. The
Timeline row removes its generic Gap badge and accessibility phrase, so global loss appears only in
the Timeline diagnostic surface.

The existing diagnostic disclosure moves directly below the Timeline toolbar/guidance and before
the scrollable Event content. It presents a fixed warning and the four bounded counters: ingress,
window, conflicts, and diagnostic loss.

The Explorer captures this global lane directly from each latest projection snapshot before filter
validation or asynchronous evaluation. It publishes immediately only when diagnostic counters
change, so superseded, cancelled, or refine-required evaluations cannot starve the warning and
ordinary Event generations do not add an extra UI invalidation.

## Capacity

`ViewerLiveProjectionLimits` changes as follows:

| Limit | Previous | New |
|---|---:|---:|
| Ingress Event count | 64 | 256 |
| Ingress accounted bytes | 20 MiB | 64 MiB |
| Retained accounted Event bytes | 32 MiB | 256 MiB |

The 32-KiB fixed accounting reserve, 16-Session metadata bound, and 100-ms UI publication cadence
remain unchanged. Retained slot and pending-key carriers continue to derive from the byte and ingress
bounds, producing 8,192 retained slots and 8,448 pending keys without a separate display suffix.

The evaluator keeps its existing 16,384 predicate-check, one-million JSON-node, and 100-ms work
bounds. A broad or expensive filter over the larger retained Session may therefore ask the operator
to refine the query rather than expanding one UI evaluation into unbounded work.

Complete-Session import/export file admission becomes 256 MiB so the transfer surface does not retain
the old 64-MiB ceiling after the in-memory Session expands. Transfer remains explicit, unencrypted,
memory-backed, and nonpersistent.

## Validation

- Unit tests assert exact limit values and derived carrier capacities.
- Projection tests prove a Session-wide ingress/window/diagnostic gap does not mark ordinary Event
  rows, while the top diagnostic snapshot remains present.
- Row-presentation tests prove generic Gap badges/accessibility state is absent, while
  controller-level tests prove global counters publish before evaluation delivery and when an older
  evaluation is superseded. Source ordering and the maintained build verify that the warning
  precedes Event content.
- Existing overflow, Clear, filtering, Performance-gap, import/export, and stable-publication tests
  remain green.
- The maintained Viewer target builds in Swift 5 mode with warnings as errors.
