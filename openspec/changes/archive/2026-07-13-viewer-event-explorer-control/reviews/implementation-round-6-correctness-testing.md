# Correctness and Testing Implementation Review — Round 6

## CT-R6-001 — P1 High: runtime-end does not join retained status publication

Both `runtimeEnded` pool-close paths omit the status signal deactivation/join used by normal storage
closure. A blocked provider can publish after cleanup or into a sequential replacement. Add the same
ordered shutdown boundary to every runtime-end path and cover blocked-provider replacement timing.

## CT-R6-002 — P1 High: late generic cancellation can overwrite committed export success

The export service seals cancellation before the irreversible rename, but the gateway independently
marks every active export as cancelled. Cancellation after rename but before gateway `finish` replaces
the successful candidate with `.cancelled`, so the UI can say Cancelled while the destination was
atomically replaced.

Make the export service's successful committed outcome authoritative at gateway finish while retaining
exact pre-start and pre-commit cancellation. Add a gateway-level after-seal race proving successful
result, replaced destination, one callback/group leave, and no stale cancellation state.

Ten focused tests pass, along with diff hygiene. Signing remains deferred and is not a finding.

**Unresolved findings: 2**
