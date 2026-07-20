# Security, Performance, and Documentation Review — Round 1

## Findings

1. Window loss could retain a prepared export and its selected-file panel longer than the design
   allowed.
2. Delayed predecessor completion could remove the current panel reference and prevent teardown
   cancellation.

## Resolution

Window loss now closes and resolves the exact active request, and request identity prevents stale
callbacks from mutating current ownership. The Viewer adds only the Powerbox-scoped
`com.apple.security.files.user-selected.read-write` entitlement; it does not add a broad filesystem
entitlement.
