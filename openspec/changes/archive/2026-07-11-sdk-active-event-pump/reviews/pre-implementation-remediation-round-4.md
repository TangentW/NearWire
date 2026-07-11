# Pre-Implementation Review Round 4 Remediation

## Finding

All three Round 4 reviews identified the same contradictory sentence in the main active-pump specification. It correctly said the initial-policy deadline continuously covers owner binding plus initial policy negotiation, but then incorrectly allowed successful wake registration to invalidate that deadline.

## Remediation

The normative wording now states that successful registration retains the same live deadline token. Only initial-policy activation or another terminal transition invalidates it. A specific deterministic task now covers successful registration followed by no Viewer offer and requires `policyNegotiationTimedOut` cleanup rather than indefinite channel, wake, waiter, or handle retention.

The design, session-admission delta, active timer requirement, timeout scenario, and prior remediation notes already used this continuous model and required no semantic change.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive` passed after remediation.
- `git diff --check` passed.

Source apply remains blocked until a fresh independent review round reports zero unresolved findings in all three dimensions.
