# Implementation Review Round 4 Remediation

Date: 2026-07-12

## Finding Status

| Round 4 finding | Resolution | Evidence status |
| --- | --- | --- |
| Handoff shutdown and cancellation notifications could complete before the independent admission reservation release | Accepted handles now retain the attempt cleanup owner. `cancelAndWait()` waits for both connection-core cleanup and the exact release callback. The cleanup registry retains handed-off attempts rather than dropping them at transfer, so the stop receipt cannot complete before slot release. The burst test now awaits the receipt instead of assuming a cancellation callback is the cleanup boundary. | **Resolved locally.** The focused receipt tests pass. `testHandoffCapacityRecyclesAcrossWavesInOneRuntime` fills 32 slots, closes eight accepted handles, deterministically observes 24 slots, refills eight in the same runtime, rejects a 33rd owner, then proves exact zero-owner shutdown. |
| The conditional stable-signer probe did not establish distinct build/signing metadata or exact unrelated-signer use, reset, and deletion denial | The probe now requires explicit create/deny/verify phases, a unique token, distinct signed bundle versions and build identifiers, separate product paths and Code Directory hashes, and runtime team/certificate/designated-requirement fingerprints. Reserved Info.plist fields carry the phase into the signed app host. The denial phase independently exercises production load, both reset APIs, exact reads, exact private-key lookup/signing use, and exact generic-password/key/certificate deletions. Verify requires an operator marker created only after denial succeeds under `set -e`, then verifies the original records before supported resets. `Documentation/Viewer-Foundation.md` records the exact command sequence; no new script was added. | **Implementation and operator recipe resolved; external execution pending.** A safe invalid-phase run proved the setting reaches the app-hosted XCTest instead of silently skipping. The host still has zero valid signing identities, so the ordinary suite reports the conditional gate as one explicit skip. Two unrelated valid identities are required to produce the final cross-build Keychain evidence. |

## Validation

The focused admission/receipt/signer-probe XCTest selection passed under the explicit ad-hoc test override, with the signer probe skipped as designed. The fresh complete Viewer suite passed with 55 tests passed, 1 explicit stable-signer skip, and 0 failures. No production or test behavior was moved into a new shell script.
