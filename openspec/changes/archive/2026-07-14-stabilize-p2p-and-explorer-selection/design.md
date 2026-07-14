## Context

The captured Viewer unified log shows the accepted connection reaching TLS 1.3 readiness over `awdl0`. The peer-to-peer daemon reports the phone's peer presence and then reports peer absence about 12 seconds after connection readiness; Network.framework reports the same path as `unsatisfied (No network route)` at 16.351 seconds. The SDK discovery coordinator currently calls `browser.cancel()` as soon as it returns the exact match, before constructing and activating the secure connection. A user can therefore send one Event near the end of that grace period and see another Event fail only a few seconds later even though the Event interval itself is short.

`enableKeepalive` is already true, but no idle or probe cadence is configured. Keepalive can detect or sometimes prevent an otherwise idle TCP path from becoming stale, but it cannot replace the peer-to-peer discovery ownership that was explicitly released during connection setup.

The Event Explorer retains rows across ordinary refresh. Retention means SwiftUI may continue delivering row selection and boundary `onAppear` callbacks while the coordinator is releasing the predecessor traversal. The Store arbiter deliberately requires an active traversal for page and detail work and ends that traversal after an invalid query operation.

Runtime reproduction also showed the first historical page immediately submitting its reverse-direction cursor from the wrong chronological edge. Store pages name cursors by continuation/reversal relative to the request direction, while the Explorer had treated `previousCursor` as always leading and `nextCursor` as always trailing. That assumption is false for an initial backward tail page and causes an immediate direction validation failure.

A second reproduction after switching recorded sessions exposed another cursor invariant: Event pages, gap pages, details, and causality queries share one sliding query lease. Each successful operation refreshes the lease idle deadline. Existing Event and gap cursors captured the deadline at issue time and required exact equality with the latest deadline, so a sibling gap or detail query made an otherwise current cursor appear invalid.

## Goals and Non-Goals

Goals:

- Keep the matched peer-to-peer Bonjour discovery alive while the secure session depends on it.
- Add a small transport-level liveness probe as defense in depth.
- Prevent retained predecessor rows from submitting Store work against a releasing or absent traversal.
- Keep a user selection pending through refresh and load its exact durable detail after the successor traversal is ready.
- Remove synchronous observable publication from the SwiftUI list-selection update transaction.

Non-goals:

- Add automatic reconnect after a genuinely terminal connection or app suspension.
- Add application-level heartbeat messages or change the wire protocol.
- Redesign the Event Explorer, pagination model, or Store query arbiter.
- Hide genuine Store failures returned by a request admitted against a ready traversal.

## Decisions

### Transfer matched discovery ownership into the session lifetime

An exact match completes endpoint selection but no longer cancels the production browser. Admission transfers the already-started discovery operation into the permanent transport core together with the selected endpoint. The core retains that operation across TLS admission, policy negotiation, and the active Event pump, and releases it exactly once on the first terminal transition. Setup failure, cancellation, and successful-session teardown share the same release path.

This deliberately keeps the peer-to-peer-enabled browser active for as long as the selected connection may use Apple peer-to-peer Wi-Fi. After selection, the discovery coordinator erases its pairing-derived expected instance name and the driver removes its state and result callbacks. The retained browser therefore becomes a silent lifetime lease: it keeps the peer-to-peer browse activity alive without converting later Bonjour snapshots, performing a second match, reconnecting, or mutating the selected identity. The pairing code and selected endpoint keep their existing one-shot semantics.

### Use explicit TCP keepalive timing as defense in depth

Both App and Viewer parameters will keep TCP keepalive enabled and set an explicit bounded idle interval. Probe interval and failure count will also be explicit, finite constants. This uses TCP control traffic rather than application Events, consumes no Event rate budget, and requires no wire-protocol state.

The setting improves continuity while both processes and the underlying peer-to-peer interface remain available. It does not promise connectivity while iOS suspends the host App or while the devices are no longer within peer-to-peer radio range.

### Gate Store-dependent row actions by traversal readiness

Event and gap pagination will be ignored unless the coordinator reports a ready traversal. A retained row may still appear during release/loading, but it cannot spend its predecessor cursor against a successor or absent query lease. Tests establish real coordinator readiness instead of bypassing ownership before controller startup.

Pausing always records a non-queryable presentation, even when pause begins from a ready traversal. This avoids stale ownership if an in-flight detail, Event page, or gap page is cancelled or fails while pause advances the presentation generation. Retained rows and already-loaded inspector content remain visible, but new durable detail, pagination, and Performance-to-Event reveal work wait until resume establishes a fresh traversal. Transient detail remains local to the live projection and can still be shown immediately.

A deferred durable exact reveal remains bound to the current Store generation and successor presentation. It is consumed only when the successor traversal is ready and still contains the exact Event identity. Store rematerialization, a nonresident successor, a newer selection, scope change, or analysis deactivation clears that intent before any row ID can be submitted.

A transient Event can still be inspected from the live projection. A durable Event selected during release/loading remains selected with a loading inspector; the controller waits for the coordinator to publish a ready successor and then submits exactly one detail request for the selected identity. A failed traversal retains its explicit failure rather than launching unowned detail work.

Obsolete page-level failures are cleared when the presentation token advances because their cursor authority belongs to the predecessor generation.

### Cursor direction determines chronological edge

Event and gap windows will map the cursor whose direction is `backward` to the chronological leading edge and the cursor whose direction is `forward` to the chronological trailing edge, independent of the direction used to obtain the current page. Pagination submits the direction carried by the selected cursor.

The Event query service will also construct a backward continuation from the oldest row and a forward reversal from the newest row when a backward page is returned, matching the already-correct gap-page boundary policy. This preserves keyset order and avoids overlap.

### Keep cursors stable across same-traversal lease refreshes

Event and gap cursors remain bound to the query fingerprint, immutable snapshot, lease identity, and direction. Their issued idle deadline is evidence that they came from the same bounded traversal, but it is not required to equal the traversal's latest sliding deadline. A cursor is accepted when its issued deadline is no later than the authoritative current lease deadline; the lease registry still validates the current lease and absolute lifetime before refreshing it.

This allows an Event cursor to survive a gap, detail, causality, or other successful operation on the same traversal without widening it to another query, snapshot, lease, or future forged deadline. The query arbiter continues to end traversal on a genuinely invalid cursor.

### Defer only the SwiftUI selection bridge

The `List` binding setter asks the controller to schedule selection on the next main-actor turn instead of mutating the observed controller synchronously. The controller binds each scheduled selection to the current presentation token and a latest-intent revision. Delivery is accepted only when both still match and a non-nil identity remains resident. Direct controller selection and programmatic exact-Event reveal both invalidate any older deferred list intent. This changes only the view-update boundary and does not add a second selection owner.

## Risks and Mitigations

- Retaining peer-to-peer discovery for the session lifetime adds nearby-network activity. This is limited to an explicitly connected session, processes no post-match discovery callbacks, and ends on every terminal path.
- More frequent keepalive probes add small idle network activity. The cadence remains fixed, transport-level, and far below Event payload traffic.
- A durable selection made during a slow refresh remains loading longer. The exact selection is retained and loads only after valid traversal ownership returns.
- Deferring list selection could deliver a stale click after the view changes. The controller revalidates sealing, latest intent, identity residency, presentation generation, and operation ownership before applying detail.
- Gating pagination could skip one boundary callback. SwiftUI may trigger it again after the ready presentation publishes; the bounded window remains usable without invalidating its traversal.
- A paused presentation cannot start a new durable inspection until resume completes a fresh traversal. This avoids submitting work after a pending release or cancelled in-flight query has ended Store ownership.
- A deferred exact reveal may disappear when the successor window no longer contains that Event or the Store generation changes. This fails closed rather than resolving a stale row ID against unrelated content.
- Accepting an older issued cursor deadline could permit a previously displayed edge to be requested again. Keyset boundaries and the immutable snapshot keep the result deterministic, while the current lease and its absolute expiry remain authoritative.

## Verification

- Assert an exact match does not cancel the browser, immediately releases pairing-derived selection state and callbacks, session setup retains the silent browser lifetime, and every terminal or failed setup path cancels it exactly once.
- Assert both App and Viewer TCP options expose the fixed keepalive enablement and timing.
- Add controller tests proving pagination is not submitted during release/loading and resumes when ready.
- Add coordinator and controller tests proving pause never claims query ownership, cannot manufacture it during release, and cannot bypass it through Performance-to-Event reveal. Cover nonresident successor windows and Store generations that reuse the same numeric Event row ID.
- Add controller tests proving a durable selection during refresh waits and then loads under the successor generation.
- Add controller tests proving a deferred selection is latest-only and is rejected after generation replacement or row eviction.
- Add Store tests proving Event and gap cursors remain usable after a sibling operation refreshes the same traversal lease, while future or foreign lease deadlines remain rejected.
- Build and run focused Core/Viewer tests and the native Viewer target.
- Inspect Viewer runtime logs for the SwiftUI publication warning and, while the attached iPhone is available, exercise repeated Event delivery beyond the previously observed route-loss window.
