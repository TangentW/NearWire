# Pre-Implementation Architecture and API Review

Date: 2026-07-12

## Scope

Independently reviewed `AGENTS.md`, the complete `viewer-application-foundation` proposal, design, both delta specifications, task plan, relevant canonical repository, pairing, TLS, secure-channel, framing, pre-handshake, negotiation, and SDK admission specifications, the current Core secure Viewer listener and wire primitives, the current root package/workspace and Viewer placeholder, the platform architecture, and the implementation roadmap. This was a lightweight artifact review focused on scope, Core-versus-Viewer ownership, project/package boundaries, identity and Bonjour lifecycle, admission handoff, and implementability without unnecessary infrastructure. No proposal, design, specification, task, source, test, or evidence file was modified.

## Findings

### 1. P1 / High — The total admission capacity and deadline do not cover pre-Hello work or interoperate reliably with the App's default admission budget

**Confidence: 10/10**

The normative limit begins too late. The capability specification limits only confirmation-pending attempts to 32 and 15 seconds (`specs/viewer-application-foundation/spec.md:82-104`), while automatic admission has no pending phase. The design repeats that confirmation-only limit at `design.md:61-65`, although its risk section more broadly promises 32 attempts and one deadline per attempt (`design.md:82-85`). Consequently, connections can be claimed, create secure channels and decoder/deadline work, then stall before a complete App Hello without consuming one of the stated 32 slots. The current listener intentionally has no connection-count bound; it emits every still-admissible incoming wrapper, and each wrapper can create one channel (`Core/Sources/NearWireTransport/SecureByteChannel.swift:639-760,785-842`). Individual channel/frame limits do not bound the number of such attempts.

The 15-second confirmation duration also conflicts with the existing App behavior. The SDK's secure-admission deadline covers TLS readiness, both Hello messages, negotiation, and approval together, with a 15-second default (`openspec/specs/sdk-session-admission/spec.md`, “Stage deadlines and cancellation clean up exactly once”). A Viewer that starts its own 15-second approval timer only after decoding the App Hello can legitimately accept within its local limit after the App's entire default admission deadline has already expired. That makes the documented confirmation boundary unreliable with an unmodified default SDK.

**Required resolution:** define one global admission capacity reserved before per-connection channel/Hello work begins and held through pre-Hello and pending approval until handoff or cancellation, in both automatic and confirmation modes. Define one monotonic claim-to-handoff/cancel deadline that is strictly inside the App's 15-second default secure-admission budget; a simple fixed 10-second Viewer budget is sufficient and avoids deadline negotiation. Capacity exhaustion must reject before channel/decoder retention, and every terminal outcome must release exactly one slot. Add the exact 32/33 pre-Hello boundary, silent/partial-Hello timeout, automatic-policy exhaustion, release, and shutdown cases to the specification and deterministic tests. This is one counter, one clock, and one terminal gate—not a new queueing subsystem.

### 2. P2 / Medium — The opaque handoff does not define the permanent channel/decoder owner or exact Viewer-Hello boundary

**Confidence: 10/10**

The design says an admission attempt decodes one App `WireHello`, verifies compatible inputs, and produces an opaque handoff; the next change “replaces only the consumer” and completes active ownership (`design.md:59-65,86`). The specification defers Hello acknowledgement but does not state when this change sends the required Viewer Hello, what exact negotiation state the handoff contains, or who continues consuming channel callbacks while approval or consumer handoff is pending (`specs/viewer-application-foundation/spec.md:82-99`).

Those details cannot safely be left to implementation convention. `SecureByteChannel` captures one immutable event handler at construction and continues receiving serial chunks for its lifetime (`Core/Sources/NearWireTransport/SecureByteChannel.swift:47-86,241-273`). Its callback cannot be retargeted from an admission object to the future session manager. The App contract also requires the first successfully decoded remote message to be exactly one Viewer Hello, then waits for the exact acknowledgement (`openspec/specs/sdk-session-admission/spec.md:41-65`). A handoff containing only a channel and decoded App metadata could therefore lose or split decoder state, mishandle bytes arriving across the handoff boundary, or force the next change to rewrite the admission owner instead of replacing only the consumer.

**Required resolution:** specify one small Viewer-owned admission connection core created before channel construction. The channel handler must weak-route to that same owner for its entire lifetime; the owner must keep one continuous bounded frame decoder, send exactly one valid Viewer Hello at the defined TLS-ready boundary, decode exactly one App Hello, retain the negotiated result and exact terminal gate, and remain the opaque handoff's owner. Approval acceptance transfers only the handle/consumer right, not callbacks or decoder state. The placeholder consumer cancels that same owner; the next change adds acknowledgement/policy/session operations behind it. Define how bytes and terminal input arriving during approval and handoff are ordered and bounded. This mirrors the already-proven continuous-owner principle in the SDK admission contract without implementing Event pumping, flow policy, persistence, or a general session framework in this change.

## Verified Architecture and Scope

- The repository split is coherent. Shared pairing, identity derivation, wire models, framing, mandatory TLS parameters, secure-channel adaptation, and the raw-Network-hiding listener wrapper remain in Core. Keychain persistence, certificate creation, listener orchestration, approval policy, AppKit lifecycle, presentation state, clipboard behavior, and SwiftUI remain Viewer-owned.
- Extending the existing repository-only secure Viewer listener with validated advertisement input and safe registration events is an appropriate narrow Core change. It preserves the current TLS 1.3, ALPN, TCP, peer-to-peer, one-shot claim, and raw `NWListener`/`NWConnection` hiding boundaries.
- The project/package plan is correct: one manually maintained `Viewer/NearWireViewer.xcodeproj`, one app and unit-test target, a relative root-workspace reference, an `XCLocalSwiftPackageReference` to the repository root, and linkage to the existing `NearWireCore` product. No nested manifest, podspec, project generator, root package dependency, or premature Demo is needed.
- The product/module naming is coherent: user-visible `NearWire.app`, with project, target, and Swift module `NearWireViewer`, macOS 13 deployment, Swift 5 language mode, and Xcode 16 or later.
- Viewer ownership of the installation UUID and non-exported self-signed TLS identity is consistent with the canonical Core contract that only adapts caller-supplied `SecIdentity`. The narrow private DER encoder is justified by the absence of a public one-call self-signed-certificate builder and is proportionately bounded by Security parsing, key-correspondence checks, fixed fields, and focused fixtures.
- The pairing/Bonjour plan reuses the canonical six-character `PairingCode`, exact `NearWire-<code>` instance, `_nearwire._tcp`, local domain, and existing `ViewerDiscoveryDiscriminator`. Publishing only `vid`, waiting for ready plus exact registration, and cancelling auto-renamed registrations match current SDK discovery semantics.
- The single-window UI and placeholder workspace keep explorer, storage, Event transfer, flow policy, charts, and multi-device session management out of scope. No cloud service, daemon, menu-bar process, project generator, or third-party runtime dependency is introduced.

## Validation

- `DO_NOT_TRACK=1 openspec validate viewer-application-foundation --strict --no-interactive`: **PASS**.
- `git diff --check`: **PASS**.

## Verdict

**Pre-implementation architecture/API approval withheld. Exact unresolved actionable finding count: 2 — one High and one Medium.**
