# Independent Review Round 1

Three independent agents reviewed the implementation before final validation.

## Architecture and Correctness

Findings:

- The Timeline used `List` row materialization as a tail proxy and deferred unversioned visibility reports. Closely spaced appear/disappear callbacks could commit out of order or after unmount.
- The test directly toggled controller state and overstated production viewport coverage.

Resolution:

- Replaced row lifecycle inference with a named-coordinate-space tail frame and viewport size.
- Added a mounted, generation-tokenized viewport reducer. Deferred publications accept only the newest mounted report, and local geometry state gates new-Event scrolling immediately.
- Added focused reducer coverage for at-tail, scrolled-away, returned, unmounted, and stale-token states. Corrected the evidence language to distinguish reducer/wiring coverage from offscreen interaction.

## Security, Performance, and Documentation

Findings:

- Raw/Pretty/Preview could synchronously lay out up to the bounded 2 MiB content on the main thread for each width change.
- Generic Preview reused the mutable Raw page instead of preserving Raw chunk zero.
- The maintained Event Explorer document still described the old row hierarchy and Tree tab.

Resolution:

- Moved debounced CoreText height measurement off the main thread, then finalized it as a serialized per-control coalescer after round-two review. It retains at most one active and the newest pending request; content revision, width, and generation guard publication. The AppKit text view remains selectable, read-only, and noncontiguous-layout capable.
- Added independent `previewRawChunk` state that is initialized from chunk zero and is unaffected by Raw navigation, plus a multi-chunk regression test.
- Updated the maintained document to the three-line row and Metadata/Raw/Pretty/Preview Inspector contract.

## UI Design

Findings:

- The deferred tail-state race could pull a user back to the bottom immediately after scrolling away.
- Documentation described content-first, one-line rows rather than the implemented type/badge/time header and three-line summary.

Resolution:

- The tokenized geometry state removes the stale callback path and uses the current local viewport decision for new-Event scrolling.
- Documentation and visual evidence now match the implemented hierarchy.

All round-one findings were actionable and were fixed before the final validation and round-two review.
