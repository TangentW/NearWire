# SDK UI Pre-Implementation Security, Performance, and Documentation Review — Round 4

## Result

**Unresolved actionable finding count: 0.**

The bounded phase-multicast redesign resolves the simultaneous-panel gap without weakening the exact-controller action, pairing-retention, or fail-closed limits approved in Round 3. Each presented panel has an independently cancellable one-value phase subscription, while Connect completion remains private to one weak origin. The artifacts provide a closed cleanup path for terminated subscribers and idle entries and retain all prior security, accessibility, distribution, and construction boundaries.

## Phase Multicast and Subscriber-Lifetime Verification

- Every presented model owns exactly one structured coordinator-phase subscription in addition to its one SDK-status observation. Each phase stream uses `bufferingNewest(1)`, immediately yields the current phase, and therefore retains at most one pending phase per live panel (`design.md:56,60-62,86-88`; `specs/sdk-ui/spec.md:17-19,45-49`).
- Phase buffering scales only with simultaneously presented panels; it does not multiply Connect, Disconnect, pairing, error, route, or cleanup ownership. Slow panels may coalesce intermediate phases but always receive the newest action gate, while coordinator admission remains authoritative.
- Every continuation has an exact identity. Stream termination removes only that continuation, and repeated subscribe/cancel or disappearance/reappearance is required to prove that terminated subscribers do not remain in the entry (`design.md:62,70,98-99`; `specs/sdk-ui/spec.md:49`; `tasks.md:17-23`).
- Multiple panels for one exact controller now remain coherent: each receives connecting, cancelling, disconnecting, and idle from the same multicast phase source, while either panel's action request is serialized by the shared coordinator. No panel displaces another subscriber.
- Entry lifetime is closed. An entry is retained while an operation is active or an exact phase subscriber remains; an idle entry is removed only when its exact subscriber count reaches zero. This prevents premature action-gate loss and stale `ObjectIdentifier` reuse while allowing successful inactive entries to be reclaimed (`design.md:68-70`; `specs/sdk-ui/spec.md:49,78-81`; `tasks.md:18,23`).
- The evidence plan covers immediate latest phase, simultaneous-panel coherence, repeated subscribe/cancel, exact subscriber removal, live subscriber counts, both asymmetric operation-completion orders, and the absence of terminated-subscriber accumulation. This is sufficient to distinguish `bufferingNewest(1)` from an unbounded or stale subscription implementation.

## Origin Completion, Action, and Pairing Bounds

- Connect safe success/failure is not broadcast. Exactly one origin-completion closure belongs to the exact Connect token, weakly references only the initiating model, and is accepted only under that model's current subscription/action generation. It neither retains a model nor forms a callback list or cycle (`design.md:62,88,98-99`; `specs/sdk-ui/spec.md:47-51`).
- The model owns no unstructured action Task. Per exact controller, the coordinator admits at most one Connect Task with one capped input argument and, only during explicit Cancel/Disconnect preemption, one additional code-free Disconnect Task.
- Connect starts only from idle. Connecting, cancelling, or disconnecting rejects repeated and successor starts, including `Connect A -> disappear -> recreate -> attempted Connect B`; model recreation cannot create a second Task or second coordinator-held input copy.
- Cancel has one closed effect: clear origin input/error authority, cancel the exact Connect Task, immediately start or join the shared Disconnect Task, and remain Disconnecting until both exact acknowledgements arrive. The two asymmetric barrier tests prevent either first completion from releasing the gate, admitting Connect B, or discarding the remaining Task.
- Ordinary disappearance remains distinct: it invalidates model generations, terminates both observations, clears model input/error, and cancels only a still-owned Connect into shared Cancelling. It starts no Disconnect and does not end an already active or concurrently committed connection.
- Pairing input is scalar-boundary limited to 64 valid UTF-8 bytes per model. Only the sole in-flight Connect argument is retained outside the origin model; it is not persisted, logged, reflected, copied to pasteboard APIs, exposed through API, status, error, or diagnostics, or claimed to be securely zeroized.

## Fail-Closed and Internal Coordinator Boundary

- Repeated Cancel/Disconnect and all panels reuse the same exact-controller Disconnect Task. There is no per-panel cleanup Task, waiter, callback, or continuation associated with SDK cleanup.
- If SDK cleanup deliberately cannot complete, one code-free Disconnect Task and its exact coordinator entry may remain for the sole process-owned route. Phase subscribers can still terminate and be removed independently; zero subscribers do not incorrectly remove the active fail-closed entry.
- The Disconnect Task captures the controller but no model, origin closure, pairing code, status, error, view, endpoint, certificate, route value, waiter list, or callback list. Exact Connect completion releases its input/origin state independently even when Disconnect remains fail-closed.
- The singleton allowance remains exact: NearWireUI may have one internal `@MainActor` process-local operation coordinator, but no global/singleton SDK facade. The coordinator creates no controller or `NearWire`, exposes no API/SPI, claims no lease or route directly, and changes no SDK lifecycle semantics (`specs/sdk-ui/spec.md:3-10,45-51`).
- Strong controller lifetime while an operation or live entry exists, exact operation/subscriber tokens, idle-zero-subscriber removal, and the explicit reuse-safety test provide a closed `ObjectIdentifier` ownership argument.

## Accessibility, Documentation, and No-Side-Effect Recheck

- Construction remains free of Tasks, timers, discovery, connection, lease claims, Keychain/storage access, notifications, and App lifecycle observation. Presentation starts only the two bounded structured observations and coordinator registration; the value-driven status view remains subscription- and mutation-free.
- No automatic connect, active-session disconnect on ordinary disappearance, retry policy, suspend/resume policy, shutdown, background execution, persistence, analytics, camera, pasteboard API, reachability, notification, or lifecycle observer is introduced.
- Pairing and unexpected error content remain protected: only content-safe `NearWireError.message` may be shown, and every other Error maps to one fixed sentence without pairing, endpoint, certificate, Viewer, framework, or application descriptions.
- The closed accessibility presentation still covers every state, retry, suspension, icon, progress, action label/hint, and error. Text plus icon avoids color-only meaning; status semantics are combined; paused/progress states are textual; Dynamic Type uses native metrics.
- Accessibility evidence remains exhaustive presentation tests plus a source-structure audit and large-accessibility-Dynamic-Type `ImageRenderer` construction. Fixed English strings are documented as non-localized, add no bundle, and carry no automatic live-region announcement promise.
- Public API remains exactly the two SwiftUI views using supported NearWire facade values. Internal controller, coordinator, phase stream, origin completion, model, action, Task, and token types remain neither public nor SPI across SwiftPM and CocoaPods inventories.
- No UIKit/AppKit wrapper, Objective-C surface, public Combine API, runtime dependency, asset, font, resource bundle, entitlement, privacy declaration, target, product, or pod subspec is added. iOS 16, macOS 13, Swift 5 language mode, complete concurrency, SwiftPM, and CocoaPods UI compatibility remain explicit gates.

## Validation Performed

- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: PASS — `Change 'sdk-ui' is valid`.
- `git diff --check`: PASS after this report was added.
- Current source inspection confirms NearWireUI still contains only its internal bootstrap marker and one module smoke test; no production or implementation test source was modified before approval.

## Final Verdict

**Ready for implementation from the security, performance, and documentation perspective.** Per-live-panel `bufferingNewest(1)` phase subscriptions, exact termination cleanup, idle entry removal, one weak origin completion, action/input/Task hard bounds, fail-closed retention, the exact internal coordinator exception, and all prior accessibility and no-side-effect guarantees are sufficiently specified and testable.
