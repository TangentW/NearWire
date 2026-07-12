# Pre-Implementation Architecture and API Review — Round 2

Date: 2026-07-12

## Scope

Independently re-reviewed the complete current `viewer-application-foundation` proposal, design, both delta specifications, task plan, all Round 1 reports, relevant canonical repository/pairing/TLS/channel/framing/pre-handshake/negotiation/admission specifications, current Core secure Viewer listener and wire primitives, root package/workspace boundaries, Viewer placeholder, platform architecture, and roadmap. This review focused on the two Round 1 architecture/API findings and checked that their remediation remained implementable without pulling active-session, Event, storage, or service infrastructure into this change. No proposal, design, specification, task, source, test, evidence, or other review file was modified.

## Findings

No unresolved actionable architecture/API finding was identified.

## Round 1 Finding Disposition

### Runtime-wide admission capacity and deadline — resolved

- One exact 32-slot budget now belongs to the Viewer runtime rather than an individual listener or the confirmation UI. Current and replacement listeners share it.
- A slot is reserved before an incoming wrapper is claimed and before channel, decoder, Task, or UI work begins. The 33rd attempt is cancelled without per-connection work.
- The same slot remains owned through TLS readiness, partial Hello input, automatic or confirmation policy, and is released exactly once at handoff or cancellation. Silent and partial-Hello peers therefore consume bounded resources in both policies.
- Every claimed attempt has one monotonic 10-second claim-to-handoff/cancel deadline. Hello completion and entry into confirmation do not reset it. The fixed deadline remains strictly within the App SDK's existing 15-second default secure-admission budget and requires no new negotiation protocol.
- The transition table now defines policy-setting snapshots, Pause, replacement preparation/commit/failure, shutdown, deadline, Accept, and Reject for claimed/pre-Hello, pending, and handed-off states. Replacement failure preserves the old registered generation; replacement commit cancels only old-generation attempts that have not been handed off.
- Tasks and tests now require the exact 32/33 cross-generation boundary, both admission policies, silent/partial peers, non-resetting deadline, slot release, control races, replacement outcomes, and shutdown cleanup. This is proportionate evidence for one counter, clock, and terminal gate.

### Permanent channel/decoder ownership and Viewer-Hello boundary — resolved

- `ViewerAdmissionConnectionCore` is now created before channel construction and remains the sole owner of the immutable channel callback, continuous bounded frame decoder, negotiation state, and terminal gate for the connection's lifetime.
- A weak ingress box routes the fixed channel callback to that owner. No admission actor, UI model, opaque handle, placeholder, or later session consumer retargets callbacks or takes decoder state.
- The core admits exactly one valid Viewer Hello at the TLS-ready boundary, decodes exactly one App Hello, verifies opposite role and compatible V1 negotiation, and serializes subsequent bytes and terminal input.
- The opaque handle grants one consumer right and strongly retains the same core. Handoff changes only consumer authority; it does not move raw bytes, Network.framework values, callback ownership, decoder state, or terminal authority.
- The foundation placeholder closes the same core. `viewer-multidevice-flow-control` is explicitly required to extend that owner with acknowledgement, policy, and active-session operations rather than replace its handler or decoder. Coalesced/early extra input is closed safely in the foundation instead of being stranded across the change boundary.
- The task plan now includes Viewer-Hello-once, continuous-owner, coalesced-input, same-core cleanup, and exact terminal/slot-release tests.

## Revalidated Architecture and API Boundaries

- Shared pairing, discovery identity, framing, wire negotiation, mandatory TLS parameters, secure-channel adaptation, advertisement validation, and raw-Network-hiding listener behavior remain in Core. Keychain and certificate lifecycle, runtime/listener orchestration, admission policy, window lifecycle, presentation, clipboard, sandbox metadata, and SwiftUI remain in Viewer.
- The Core change stays narrow: configure `NWListener.Service` before start and emit safe registration events while preserving TLS 1.3, NearWire ALPN, TCP, peer-to-peer inclusion, one-shot connection claim, and cancellation atomicity. It does not move Bonjour UI or Viewer policy into Core.
- The manually maintained Xcode project, local root-package reference, existing `NearWireCore` product linkage, relative workspace reference, `NearWireViewer` module name, `NearWire.app` product name, macOS 13 deployment, and Swift 5 language mode remain coherent. No nested manifest, podspec, project generator, root package dependency, premature Demo, or third-party runtime dependency is introduced.
- Viewer still owns both persistent identities while Core only adapts the supplied `SecIdentity`. The fixed private X.509 profile and exact data-protection Keychain selectors are detailed but bounded; they do not create a general ASN.1/CA subsystem or external dependency. Scoped TLS reset, confirmed full identity reset, one repair/renewal attempt, and foreign-item preservation are implementable behind Viewer-internal interfaces.
- Pairing and Bonjour still reuse the canonical six-character `PairingCode`, exact `NearWire-<code>` instance, `_nearwire._tcp`, local domain, and existing `ViewerDiscoveryDiscriminator`. Only `vid` is advertised, and pairing readiness still requires listener readiness plus exact-name registration.
- App Sandbox, server-only networking, Info.plist Bonjour/local-network declarations, Viewer-owned privacy resource, and built-product inspection are attached only to the Viewer project and do not alter the root Swift Package or CocoaPods distribution.
- The scope remains a foundation: active acknowledgement, flow policy, Event transfer, multi-device sessions, persistence, search, explorer/control UI, charts, Demo, daemon, and menu-bar lifetime remain explicitly deferred. The permanent admission core is the minimal seam needed to make that deferral real rather than a partial future session manager.

## Validation

- `DO_NOT_TRACK=1 openspec validate viewer-application-foundation --strict --no-interactive`: **PASS**.
- `./Scripts/verify-english.sh`: **PASS**, with the expected human semantic-review note.
- `git diff --check -- openspec/changes/viewer-application-foundation`: **PASS**.

## Verdict

**Pre-implementation architecture/API approval granted. Exact unresolved actionable finding count: 0.**
