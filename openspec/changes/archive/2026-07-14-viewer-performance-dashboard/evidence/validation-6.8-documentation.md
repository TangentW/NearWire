# Validation 6.8 Evidence: Viewer Performance Documentation

Date: 2026-07-14

## Documentation delivered

`Documentation/Viewer-Performance.md` documents the operator and engineering contract for the
single-device Performance dashboard. It covers:

- raw durable Events and the bounded current live window as the only authority;
- the one-, five-, and fifteen-minute ranges plus current session, inclusive Viewer receive-time
  ordering, current freeze, and historical anchors;
- the 12 current cards, the complete 16-metric availability inventory, displayed units, freshness,
  stale, unavailable, not-collected, and invalid semantics;
- exact bucket geometry, six chart groups, shared mouse/keyboard crosshair, aggregate tooltip, and
  accessibility summaries;
- conservative gap placement, unplaced gaps, metric-specific discontinuities, and bounded detail
  loss;
- exact raw-Event reveal without neighboring-row substitution;
- refresh, pause, lifecycle cleanup, generation rejection, deterministic work/memory bounds, and
  failure behavior;
- privacy controls, V1 exclusions, unsigned development coverage, and the deferred stable-signer
  release gate.

The root `README.md` and `Viewer/README.md` link the new guide. Its SDK collection and Viewer
identity references resolve to existing repository documentation.

## Coverage and link checks

```text
rg -n -i \
  "raw|1 min|5 min|15 min|Session|card|unit|receive time|bucket|crosshair|gap|unavailable|stale|invalid|Open Source Event|bound|privacy|cleanup|exclude|sign" \
  Documentation/Viewer-Performance.md
exit 0; every required documentation dimension matched

ls Documentation/Viewer-Performance.md Documentation/SDK-Performance.md \
  Documentation/Viewer-Foundation.md Documentation/Viewer-Event-Explorer.md
all four files listed; exit 0

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid
```

The signing text explicitly separates unsigned dashboard validation from the configured
stable-signer cross-update gate deferred to final Goal release hardening.
