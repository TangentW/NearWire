## Context

Timeline rows already derive stable identities and bounded content summaries outside SwiftUI. Their secondary line nevertheless repeats Device alias, direction, priority, and byte count, even though the Inspector exposes those fields. `autoFollow` is currently controller state only: the `List` does not observe its enclosing `NSScrollView`, so arrival does not reliably follow the tail and manual scroll position cannot own the follow decision.

Inspector content is prepared from one bounded canonical in-memory buffer. The Raw and Pretty views use a hardened AppKit text view that intentionally disables all selection and responder commands. The Tree tab adds a second JSON navigation representation that the product no longer needs. For ordinary Event types, the immutable renderer registry correctly chooses Generic JSON, but the UI renders only guidance telling the operator to visit another tab, which makes Renderer appear broken.

## Goals and Non-Goals

Goals:

- Keep Timeline rows quiet and content-led while retaining exceptional diagnostics.
- Match console tail behavior: follow only while the viewport is already at the bottom.
- Keep selection, scroll position, and layout stable during ordinary Event arrival.
- Reduce Inspector choices to Metadata, Raw, Pretty, and a useful Preview presentation.
- Allow deliberate, native text selection and copying from Raw and Pretty without enabling editing, paste, drag, or background clipboard writes.

Non-goals:

- Change Event admission, transport, filtering, retention, or Session behavior.
- Add arbitrary renderer plugins, editable JSON, clipboard history, sharing, or persistence.
- Redesign specialized renderer schemas or add a new Event type convention.
- Add Tree or Causality information elsewhere.

## Decisions

### Timeline rows contain only scan-oriented information

The top line places Event type, exceptional status, and receive time on the same horizontal level. At ordinary widths it shows each exceptional badge. If those badges cannot fit at the supported minimum width, the header replaces them with one compact status-count badge rather than wrapping or hiding the Event type and time; accessibility still names every state. The bounded content summary follows beneath it and may wrap to at most three lines before tail truncation. Badges never create another row. Device/source, direction, priority, and byte count remain in Metadata. Normal disposition remains hidden, while gap, drop, conflict, terminal, and other non-normal states remain represented because they change interpretation of the Event.

Accessibility output follows the same hierarchy: Event type, exceptional states, receive time, and summary. Removed visual metadata is not silently repeated in the row accessibility label because it remains navigable in Metadata.

### Tail following is derived from real viewport geometry

The Timeline `List` owns a stable zero-content tail anchor inside a `ScrollViewReader`. The anchor reports its frame in a named coordinate space, while the List container reports the viewport size. A local mounted state reducer compares those values and produces a generation token for each decision. Deferred controller publication accepts only the latest token from the mounted viewport, so an obsolete geometry report cannot overwrite a newer scroll decision or survive unmount. The presentation uses the current local decision before a row-set change:

- if a new last Event identity arrives while the prior viewport was at the bottom, it scrolls the document to the bottom after the List completes layout;
- if the operator scrolls upward, subsequent Event arrival does not move the viewport;
- if the operator reaches the bottom again, tail following resumes;
- Jump to Latest issues an explicit scroll request and restores follow state;
- Pause never changes capture and does not manufacture a scroll backlog.

Viewport observation and programmatic scrolling remain local presentation behavior. Geometry callbacks are deferred outside the active SwiftUI update transaction before publishing controller state, avoiding mutation-during-render warnings. Arrival scrolling is not animated, so rows do not flash or slide during high-frequency updates.

### Inspector exposes four distinct jobs

The visible tabs become Metadata, Raw, Pretty, and Preview. Causality remains absent. Tree UI, controller state, generic preparation fields, and Tree-only tests are removed; the bounded JSON range scanner remains because specialized table, log, and numeric renderers use it.

Preview is the user-facing name for the existing immutable Renderer selection. Known `log.*`, `table.*`, `chart.*`, and `timeline.*` Events retain their specialized bounded presentations. Other Event types show the already-prepared Pretty JSON when available, otherwise the first bounded Raw chunk plus closed guidance. A generic Event therefore always presents useful content instead of an empty instruction card.

### Inspector text is selectable but remains a read-only disclosure surface

`ViewerReceivedEventTextView` becomes first-responder-capable and selectable. It validates only Copy and Select All, provides only those context-menu actions, remains noneditable, disables rich content and link detection, unregisters dragged types, and clears its text on dismantle. No copy occurs without a user action.

The enclosing scroll view disables horizontal scrolling. Its document view tracks the clip width and uses an unbounded vertical text container. Debounced CoreText height requests run through a per-control serialized coalescer that retains at most one active request and the newest pending replacement. Cancelling or dismantling the control clears the debounce and pending request; generation, content-revision, and width guards reject a stale active result. Raw and Pretty therefore wrap long lines and retain vertical scrolling without synchronously laying out the full bounded payload during every main-thread width change or starting overlapping large measurements. Specialized Preview content may reuse the same control where it presents received text.

## Risks and Mitigations

- SwiftUI may emit several geometry reports while adding a row. The local frame-against-viewport decision is available synchronously to arrival handling, and only the newest mounted generation may publish to the controller.
- Geometry callbacks can arrive close together during layout. Token-checked deferred publication suppresses stale state changes and never mutates the model during a render update.
- One already-active background text measurement can complete after content or width changes. The serialized worker bounds retained work to that active request plus the newest pending request, while cancellation clears pending work and generation, content-revision, and width checks discard stale results before they can resize the document view.
- Selectable received content creates a clipboard disclosure path. Only explicit Copy is enabled, the existing accessibility escaping remains bounded, and no automatic clipboard, drag, persistence, or analytics path is added.
- Removing Tree could accidentally remove the JSON scanner used by specialized renderers. Only Tree state and expansion code are removed; scanner-based renderer tests remain.

## Verification

- Focused Timeline tests cover row presentation and the frame-against-viewport reducer for arrival at bottom, arrival while scrolled up, returning to bottom, stale reports, unmount, and Jump to Latest controller behavior.
- AppKit text-control tests cover wrapping, selection, Copy/Select All validation, rejection of editing/paste/drag behavior, and sensitive-state cleanup.
- Renderer tests cover meaningful Generic JSON preview data and preserve specialized selection/fallback bounds.
- Viewer tests, strict-concurrency build, Viewer build, strict OpenSpec validation, and a focused visual check provide final evidence.
