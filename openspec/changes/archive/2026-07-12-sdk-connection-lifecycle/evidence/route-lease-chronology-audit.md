# Route and Lease Chronology Audit

## Initial Attempt

The actor installs pending intent, exact attempt token, transition gate, and cleanup receipt before claim. Pairing and connection-limit validation precede reservation and claim. Direct cleanup invokes release, settles the exact receipt, then clears the slot. After admission, the sole terminal coordinator owns lease release and captures the exact receipt.

## Active Terminal

The permanent core marks terminal on the shared transition gate. The terminal coordinator waits once, then invokes a code-free weak-actor callback that installs one exact token-and-receipt cleanup marker before release begins. Explicit preflight reports `connectionInProgress` while that marker exists. The coordinator invokes exact lease release and then delivers the route token, receipt, and closed terminal code. Delivery settles the receipt and clears the exact marker before checking whether lifecycle generation remains current. Only a current active slot may change state or schedule recovery.

## Replacement

Recovery is scheduled only from the post-release actor delivery. Its delay Task contains generation, attempt, delay, and cancellation state but no pairing code or route. On wake, the actor reauthorizes intent and constructs a new attempt through the same discovery, TLS, hello/admission, pump, and coordinator pipeline. Tests prove claim 2 follows release 1, pre-active transport failure cannot retry through public-error reclassification, and a stale/cancelled delay cannot claim.

## Disconnect and Suspension

Callers join the receipt's shared Task rather than entering an actor waiter array. One exact command token gives the latest disconnect/suspension command sole post-cleanup publication authority; both command orders preserve the latest suspension latch. Cancellation of a caller does not make the nonthrowing operation return before receipt completion. A terminal-wait failure deliberately leaves cleanup incomplete and the lease vaulted. Runtime release enter/exit failures do not clear a wrong token or promise reacquisition.
