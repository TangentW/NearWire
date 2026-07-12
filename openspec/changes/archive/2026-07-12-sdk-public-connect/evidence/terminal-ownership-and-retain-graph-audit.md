# Terminal Ownership and Retain-Graph Audit

## Ownership sequence

1. The actor attempt owns the exact process lease before a session lifetime exists.
2. Admission receives the same `SDKSessionTransitionGate` used by public cancellation and actor authorization.
3. After admission, the gate acknowledges coordinator lease ownership before the attempt clears its handle.
4. One coordinator registers the lifetime's one-shot termination wait before pump attachment.
5. The core synchronously marks the gate at its first terminal transition.
6. The coordinator releases only after that wait returns a terminal code, then invokes a weak tokenized actor callback.

A wait-registration failure and a wait-execution failure both move the lease to the permanent fail-closed vault. Neither path treats missing terminal evidence as permission to release.

## Cancellation and linearization

`SDKSessionTransitionGate` owns cancellation chronology, terminal chronology, monotonically increasing target generations, active transfer, and connected commit. Target replacement is exact-token atomic. Every target carries a one-shot cancellation cell, so nested Task handlers, repeated Task cancellation, and repeated shutdown cannot notify the same owner twice. The cancellation-result API reports target delivery in the same locked operation, eliminating the prior check-then-cancel gap.

Critical-section tests cover both winners for terminal versus active transfer and terminal versus connected commit. Public async barriers cover cancellation at admission-result and activation-result replacement, plus release-before-terminal-delivery ordering. Public tests also cover cancellation before claim, blocked claim failure, after-claim cancellation, identity, discovery, phase authorization, secure admission, active terminal, shutdown, and successful post-terminal release.

Facade-level scripted runtime tests exercise claim-exit, release-enter, and release-exit failures. Claim-exit maps to ownership-unavailable with zero identity work. Release-enter leaves the token contended on retry. Release-exit invokes no second runtime release and makes no public reacquisition promise. A macOS child process claims the real registry lease, injects terminal-wait failure, drops ordinary owners, and proves a second real registry claim remains contended until child-process exit.

## Retain graph

- A pending instance-method connect Task intentionally retains `NearWire` until the attempt completes.
- The permanent core stores App rates by value and owner operations capture `NearWire` weakly.
- Connected ownership is `NearWire -> connected owner -> handle/coordinator`; the core and coordinator have no strong edge back to `NearWire`.
- The coordinator Task captures the coordinator, lifetime wait registration, lease, hooks, and a weak delivery closure. It retains no pairing value, Event, endpoint, certificate, metadata, or internal error.
- Dropping the final external `NearWire` reference deinitializes the actor, cancels the hidden handle, terminates the core, and lets the sole coordinator release the lease. The deterministic deinitialization test proves the weak actor becomes nil, the driver sees one cancellation, and release occurs once.
- Public and admission pairing transfers are consumed in narrow synchronous helpers before the next suspension. `testPairingTransferClearsOwnershipAfterOneSynchronousTake` proves the public transfer is immediately empty and one-shot. Both public-admission cancellation-order tests hold discovery at its first suspension and prove the admission actor no longer retains pairing ownership. Connected, terminal, Keychain, channel, and callback owners contain no pairing field. The contract promises reference minimization, not String memory zeroization.
