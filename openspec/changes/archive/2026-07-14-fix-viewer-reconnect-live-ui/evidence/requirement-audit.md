# Spec-to-Evidence Audit

Date: 2026-07-15

## Viewer multi-device flow control

- Finite current and displaced ownership: manager bounds plus capacity/replacement tests.
- Attach-before-commit and failed-attachment preservation: injected attachment failure test verifies the current owner and capability remain authoritative.
- Exact-route newest-session ownership: takeover tests verify the old capability is revoked, new state is independent, and additional replacement is rejected while cleanup is pending.
- Shutdown and cleanup ownership: manager cleanup tests and the full Viewer suite pass.
- Maintained documentation records correlation as unauthenticated and describes the residual availability risk.

## Viewer Event Explorer control

- Stable ordinary refresh: retained-window tests verify rows do not flash empty and absent lanes are valid bounded clears.
- Detail and selection ownership: tests cover pending-detail reload, release/query failure, partial successor removal followed by another lane's failure, and complete inspector buffer clearing.
- One Event presentation: unique immutable-field bridge succeeds and ambiguous Event UUID candidates fail closed.
- Bounded pagination: repeated Event and gap boundary triggers admit one operation per lane.
- Filter layout: offscreen minimum-size render verifies grouped scrollable layout and retains a visual attachment.
- Existing receive-order, keyset, bounded-window, gap, and filter behavior remains covered by the full 409-test Viewer suite.

## Viewer Performance dashboard

- The analysis workspace directly observes the mode coordinator.
- A rendered-state regression verifies Events-to-Performance changes the UI immediately after coordinator publication.
- Existing traversal arbitration and source-identity behavior remains covered by the full Viewer suite.

## Delivery boundary

- Strict OpenSpec validation passed.
- Focused regressions passed.
- Full Viewer suite passed: 409 executed, 2 intentional skips, 0 failures.
- Unsigned Viewer application build passed.
- Physical iPhone reconnect and AWDL recovery remain a documented later smoke-test item because the user made the phone unavailable for this run.
