# Change: Centralize Viewer gap warning and expand memory capacity

## Why

The Viewer currently projects a Session-wide ingress, retention-window, or diagnostic loss onto
every retained Event row. One historical loss therefore makes all later rows look individually
incomplete, even though the diagnostic cannot be attributed to those Events. The current
64-Event/20-MiB ingress and 32-MiB retained window also reach their limits too quickly for sustained
internal debugging sessions.

## What Changes

- Present Session-wide gap state once at the top of Event Timeline instead of adding a Gap badge to
  every Event row.
- Preserve exact per-Event conflict, drop, terminal, and other exceptional presentation.
- Increase Viewer projection ingress to 256 Events and 64 MiB.
- Increase retained Event accounting capacity to 256 MiB and keep the carrier byte-derived rather
  than imposing an independent Event-count suffix.
- Align complete-Session JSON transfer admission with the 256-MiB retained Session capacity.

## Scope

This change affects only Viewer in-memory presentation, Event Timeline diagnostics, and complete
Session transfer bounds. It does not change SDK buffering, negotiated single-Event size, protocol
framing, rate policy, persistence, or Performance gap semantics.
