# Pre-implementation Round 4 Finding Remediation

## Scope

This record resolves the single correctness finding from the fourth independent pre-implementation review round. Architecture/API reported zero findings. No production or test source was modified.

## Failure Cleanup Serialization

- A post-start sampling or submission failure now enters the same internal Stopping barrier used by explicit stop, with a fixed Failed terminal target.
- The run worker releases every task-owned external resource and emits an exact cleanup receipt as its final step. The actor cannot discard the predecessor Task handle or publish Failed before validating that receipt.
- Start during failure cleanup waits for the receipt and then starts fresh, so old and new resources cannot overlap.
- Explicit stop during failure cleanup joins the same barrier and changes its pending terminal target to Stopped. Cleanup runs once and no Failed value is published.
- Tests now cover receipt ordering, start/stop during slow failure cleanup, terminal-target override, cancellation, stale receipts, exact resource counts, and publication sequences.
