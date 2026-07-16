# Design

## Timeline-local momentum interception

A small AppKit bridge resolves the `NSScrollView` owned by the SwiftUI Timeline List and installs
one local scroll-wheel monitor for that mounted Timeline only. The monitor records momentum began,
changed, ended, and cancelled phases only when the event belongs to the same window and lies within
the Timeline scroll view.

When the Timeline's last real Event identity changes, the bridge checks whether momentum is active.
If so, it commits the current clip-view origin without animation and suppresses only the remaining
momentum movement events. The terminal ended or cancelled event is allowed through so AppKit resets
its gesture state without applying another delta. A later ordinary gesture also clears suppression
immediately. Events outside the Timeline and non-momentum wheel events pass through unchanged.

The bridge removes its monitor when the Timeline unmounts. A closed state machine owns the momentum
and suppression transitions so behavior can be tested without synthesizing system input.

## Tail-follow interaction

Stopping momentum does not schedule a tail scroll. Existing viewport observation remains the sole
authority for `autoFollow`. If the operator was reading older Events, the current origin remains
stable. If the Timeline was already following the bottom independently of the momentum sequence,
the existing nonanimated tail reveal remains available.

## Verification

- Test momentum began, stop request, suppressed changed events, terminal reset, and later gestures.
- Host a populated Timeline, append an Event while reading above the bottom, and confirm the visible
  origin remains stable.
- Run focused Viewer tests, the Viewer foundation test class, build, and self-review.
