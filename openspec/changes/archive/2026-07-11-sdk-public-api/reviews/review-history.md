# SDK Public API Review History

## Round 1

Architecture and API review found that replies lacked instance/session route affinity, clear and diagnostics could miss long-lived reservations, and the optional performance module had no narrow way to submit reserved platform events. The implementation added hidden instance and route affinity, removed reservations in favor of queue-owned work, and added the `NearWireBuiltins` SPI.

Correctness review found that reservation restoration could mutate event identity, generated IDs could collide or be reported inaccurately, and stream cancellation/race coverage was incomplete. The implementation added live-ID collision checks with a typed exhaustion error, eliminated reservation reconstruction, exposed test-only subscriber counts, and added cancellation, finish, and overflow races.

Security and distribution review found that CocoaPods same-module compilation exposed Core declarations, consumer checks did not cover both iOS integrations, and the pod path lacked a real public API test specification. All Core declarations moved behind `NearWireInternal` SPI, forbidden-consumer and filtered API-inventory gates were added, canonical iOS consumer sources now compile through both integrations, and the podspec owns a `PublicAPI` test specification.

## Round 2

Architecture review found that a synchronous drain closure could not call actor-isolated `SecureByteChannel.send`. Correctness review found that dequeue followed by re-enqueue changed FIFO ordinals and weighted scheduler state on transport rejection. The secure channel gained a bounded synchronous mailbox admission operation, and the queue gained transactional candidate offering that removes work only after acceptance.

Distribution review questioned whether SwiftPM and CocoaPods exercised the same source. The duplicate fixtures were removed; both manual integration gates and the CocoaPods test specification now use `SDK/Tests/PublicAPIConsumer`.

## Round 3

Review found four issues:

1. OpenSpec still described an SDK-only change despite new queue and transport handoff primitives.
2. SwiftPM/CocoaPods API parity compared a macOS SwiftPM inventory with an iOS CocoaPods inventory.
3. An encoding deferral was counted as an actual transport-mailbox rejection.
4. A route-mismatched reply larger than the transport byte budget could block the queue before route validation ran.

The proposal, design, tasks, and modified Core capability deltas now cover both primitives. API parity compares iOS 16 SwiftPM to iOS 16 CocoaPods. Drain results distinguish not-attempted encoding from mailbox rejection. Queue preflight removes route-invalid work before transport-byte accounting. Dedicated regressions cover each behavior.

## Round 4

Architecture and security/distribution/documentation reviewers reported zero unresolved findings. Correctness review found that selecting a candidate at an exhausted weighted-cycle boundary could reset scheduler credits even when the candidate was not removed.

The queue now snapshots credits before selection and restores them for preflight stop, byte-budget stop, and admission stop. Regressions cover both explicit offer rejection and byte-budget rejection after eight critical-priority services.

## Round 5

Fresh architecture/API, correctness/testing, and security/performance/distribution/documentation reviews each reported zero unresolved findings.

