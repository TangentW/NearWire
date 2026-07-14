# Implementation Round 8 Architecture and API Review

Date: 2026-07-14
Verdict: Changes requested

## Finding

1. **P1 — post-Live historical selection retained the prior live scope:** explicit Live recovery
   completed its receipt while Store authority remained unresolved. A dirty successor could
   repopulate historical source rows; selecting one changed the UI source, but historical
   materialization failed and left the previous live request/traversal installed. Unresolved
   historical selection after Live recovery must clear the live scope and start a fresh logical-ID
   rematerialization.

All prior receipt, selected-row, exact-device, action-matrix, snapshot, export, dirty-successor,
cleanup, package, and API findings otherwise passed. Four focused tests, strict OpenSpec validation,
diff checks, and package inspection passed. Signing work was excluded under the Goal-level deferral.
No files were changed by the reviewer.
