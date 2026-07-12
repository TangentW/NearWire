## Context

The repository currently exposes a tested mandatory-TLS Viewer listener and shared Bonjour/pairing primitives through repository-only SPI. Core deliberately does not own TLS private-key lifecycle, Viewer UI, admission policy, or AppKit window lifecycle. `Viewer` contains only a README, and the root workspace has no concrete Viewer project reference.

This change must produce a native macOS 13 application built in Swift 5 language mode with Xcode 16 or later. It must preserve the repository boundary: platform-neutral protocol and transport adaptation stay in Core, while Keychain identity management, listener orchestration, approval policy, and SwiftUI stay in Viewer.

## Goals / Non-Goals

**Goals:**

- Create a buildable, testable, manually maintained Viewer app and one root-workspace reference.
- Make the main window the explicit owner of one listener generation.
- Persist a Viewer installation ID and self-signed TLS identity in Keychain and fail closed when either cannot be loaded or created.
- Generate and present an ephemeral pairing code only after the exact Bonjour service is registered.
- Admit new App connections automatically by default, optionally wait for explicit confirmation, and bound pending work.
- Leave an accepted connection in an opaque handoff type that the next Viewer session change can consume without exposing raw Network.framework values to UI code.

**Non-Goals:**

- Active Event-lane pumping, flow-policy execution, device session recovery, multi-device event routing, or queue telemetry.
- SQLite storage, search, export, event timelines, renderer plugins, control-event composition, or performance dashboards.
- Multiple Viewer windows, a menu-bar agent, background daemon behavior, launch-at-login, notarization/external distribution, or a Demo project.
- Strong Viewer authentication, certificate pinning, a pairing password, client certificates, or plaintext fallback.

## Decisions

### 1. One manually maintained Xcode project owns the application

`Viewer/NearWireViewer.xcodeproj` contains an application target and unit-test target. The application product name is `NearWire.app`; `PRODUCT_MODULE_NAME` is `NearWireViewer`; deployment target is macOS 13; and `SWIFT_VERSION` is `5.0`. The maintained app uses automatic Apple Development signing after an internal team is selected; Developer ID may replace it for a distributed internal build. Stable signing is part of the persistent login-Keychain identity contract. Ad-hoc signing remains an explicit command-line override only for isolated tests and structural product inspection, not a supported cross-update persistence identity. The project uses an `XCLocalSwiftPackageReference` to the repository root and links only the `NearWireCore` product. It adds no package to root `Package.swift` and no Viewer source to CocoaPods.

The existing root `NearWire.xcworkspace` gains one relative file reference to this project. Demo is intentionally not fabricated early.

### 2. The main window owns a single runtime generation

The SwiftUI application uses one `Window` scene rather than `WindowGroup`, removes the New Window command, and creates one `@MainActor` application model. Window appearance starts a fresh runtime generation; window disappearance or application termination initiates idempotent shutdown. A token prevents late identity, listener, registration, or admission callbacks from reviving a stopped generation.

Shutdown immediately prevents new handoff, deactivates listener ingress and its generation-scoped pending-UI coalescer, cancels publication/listening and all pending approvals, and returns one idempotent cleanup receipt. A manager-owned registry retains every attempt from before synchronous claim through completed channel cleanup, including work removed earlier by Pause, Reject, timeout, replacement, or failure. One handoff owner atomically serializes transfer with shutdown and joins all accepted-handle cleanup into the same receipt. Window close, identity reset, retry, and application termination wait for that receipt for at most one second before continuing; cleanup ownership remains alive if the bound expires. It never waits for an unbounded Event queue or database because neither exists in this change. The application terminates after its last window closes, so no hidden listener or menu-bar lifetime remains. App-hosted XCTest deliberately suppresses only the scene's automatic production startup, allowing tests to instantiate isolated application models without racing the real login-Keychain runtime.

### 3. Viewer owns two separate persistent identities

Viewer stores a random installation UUID and a self-signed TLS identity under distinct versioned Keychain service/tag names. The installation ID is an `EndpointID` source and remains stable across pairing-code refreshes. The TLS identity consists of a non-exported Keychain private key plus a self-signed leaf certificate and is adapted through existing `ViewerTransportIdentity` SPI.

Identity creation uses Apple Security APIs only. A small internal DER encoder constructs one fixed X.509 v3 profile: P-256 `id-ecPublicKey` with `prime256v1`, ECDSA-with-SHA256, a positive nonzero 16-byte random serial no larger than 16 encoded octets, fixed subject and issuer `CN=NearWire Viewer Local TLS`, and no pairing or installation value. Validity begins five minutes before creation and ends 3,650 days after creation. DER time uses UTCTime only through 2049 and GeneralizedTime from 2050 onward, with strict parsing for both forms. Extensions are critical `basicConstraints CA=false`, critical `keyUsage digitalSignature`, and noncritical `extendedKeyUsage serverAuth`; subject alternative name, name constraints, certificate policies, AIA, CRL distribution, and every network-fetching extension are absent.

`SecKeyCreateSignature` signs the exact TBS bytes. Load/create validates DER parsing, the fixed profile, self-signature with `SecKeyVerifySignature`, private/public key correspondence, Basic X.509 trust using the leaf as its only anchor, and current validity. A certificate with less than 30 days remaining, an expired/not-yet-valid certificate, a mismatch, or a partial record triggers at most one stop-before-repair regeneration; another failure is terminal. This is the only automatic identity renewal and is documented as an expiry safety exception to ordinary identity stability. The encoder is not a general ASN.1 library. Unit tests cover DER lengths, serial normalization, profile rejection, boundary dates, real Security parsing/trust, stable reload, repair, renewal, and reset.

Viewer uses `SecItem` against the standard per-user macOS login Keychain (`kSecUseDataProtectionKeychain=false`) with synchronization disabled and no Keychain-sharing entitlement. The file-based Keychain protects sensitive operations with the app's code-signing requirement, so maintained builds must keep a stable Apple Development or Developer ID signer across updates. Reads, existence checks, exact identity assembly, and deletes receive an `LAContext` with interaction disabled so startup and recovery fail closed instead of presenting an unexpected Keychain prompt. There is no broad default-Keychain identity fallback or arbitrary-app ACL. The installation ID is one generic-password item selected by exact service `com.nearwire.viewer.identity.v1` and account `installation-id`. TLS metadata is a second generic-password item under account `tls-metadata`; it records the owned certificate persistent reference, random non-identifying certificate label/serial, certificate hash, and public-key hash. Private-key creation requests permanent and sensitive P-256 storage. Reload selects the key by exact application tag `com.nearwire.viewer.tls-key.v1` plus key class/type, validates its P-256 size, proves actual nonexportability, and exercises signing use at the update boundary. The login-Keychain `SecKey` reference does not reliably return readable `kSecAttrIsPermanent` or `kSecAttrIsSensitive` values, so those creation attributes are not treated as a portable reload assertion. The certificate persistent reference is resolved through `kSecMatchItemList`, then cross-checked by fixed profile, self-signature, serial, certificate hash, public-key hash, and exact private-key correspondence before deletion. The human-readable label is nonauthoritative. Missing or damaged metadata never authorizes deletion of an arbitrary certificate.

The release-only update gate remains an app-hosted XCTest rather than a new shell harness. Explicit create, unrelated-signer denial, and same-signer verification phases use three separate build products, distinct signed bundle versions, and operator-provided build identifiers. Reserved Info.plist fields bind the explicit phase build settings to the signed app host; normal builds leave them empty. The test records the signed host Code Directory hash, bundle version, product path, team identifier, signing-certificate hash, and designated requirement. It refuses to run the destructive denial phase unless the signed build metadata differs and the designated requirement is unrelated. That phase separately attempts exact non-interactive reads, private-key lookup/signing use, both production reset scopes, and exact deletion of every owned record class. Verify additionally requires a non-sensitive completion marker created by the operator only after the denial test succeeds. The final same-signer product must match the complete stable identity fingerprint, prove the original records and signing key remain intact, and only then exercise supported reset. Normal ad-hoc unit runs skip this conditional gate; the operator documentation contains the exact command sequence.

Load/create is transactional from the runtime's perspective: no listener or pairing code is created until both identities are ready. Partial or mismatched owned records are removed and regenerated once. A second failure enters a safe UI error with `Retry`, `Reset TLS Identity`, and a separately confirmed `Reset All Viewer Identity`; it does not expose OSStatus text, selectors, labels, certificate bytes, fingerprints, or private-key data. TLS reset closes listener/admission, deletes only the exact metadata-referenced certificate, exact key tag, and TLS metadata, and preserves installation ID. Full reset performs the same stop, deletes both exact generic-password accounts plus exact TLS items, and regenerates all identity. Partial deletion or recreation fails closed and never resumes an old listener. Pairing refresh never rotates either persistent identity.

### 4. Pairing code generation is unbiased and memory-only

A generator draws bytes with `SecRandomCopyBytes` and uses rejection sampling over the 31-character canonical alphabet. It constructs the existing Core `PairingCode`; it never uses timestamps, `SystemRandomNumberGenerator`, modulo-biased reduction, or persistence. One listener generation retains one code. Copying is a user action through `NSPasteboard`; logs, errors, analytics, session records, and Keychain never receive it.

Refresh starts a replacement listener with the same persistent identities and a new code. The old publication stops only after replacement startup has taken ownership; accepted connections already handed off are not cancelled. `Refresh and Disconnect All` is deferred until the multi-device session manager exists.

### 5. Bonjour configuration remains inside the secure listener boundary

Core gains an internal validated advertisement value containing the expected instance name, canonical NearWire service type/domain, and bounded TXT record. `SecureViewerTransport.makeListener` installs `NWListener.Service` before start, keeps `includePeerToPeer` from the existing TLS parameters, and forwards only safe registration state: expected-name registration success, mismatch, removal, or terminal failure. It still never exposes raw `NWListener`, `NWConnection`, endpoint descriptions, or underlying errors.

The Viewer publishes only `vid` in V1 TXT data because the current SDK consumes only that key. `vid` is derived from the stable installation ID with existing Core logic. The UI does not show the pairing code as ready until listener readiness and exact service registration have both occurred. If Network.framework auto-renames the instance, the runtime cancels that listener, generates a new code, and retries a bounded number of times. Exhaustion becomes a safe actionable failure rather than publishing a misleading code.

### 6. Admission is a bounded handoff, not the future session manager

Each incoming TLS connection is claimed once into the existing bounded secure channel. A Viewer admission attempt accepts only the allowed pre-session Control sequence, decodes one bounded App `WireHello`, verifies the App role and compatible V1 negotiation inputs, and produces a safe `PendingAppSummary` plus an opaque connection handoff. It does not start Event transfer or send flow policy; the next change consumes the handoff and completes active session ownership.

One runtime-wide connection-owner budget shared by current and replacement listeners contains exactly 32 slots. A slot is reserved before an incoming wrapper is claimed and remains owned through TLS/channel readiness, partial hello decoding, optional confirmation, asynchronous cancellation completion, and placeholder-handoff cleanup. The 33rd connection is cancelled without a channel, Task, decoder, or UI row, including while all earlier attempts are already terminal but still cleaning up. Each attempt has one monotonic 10-second decision deadline measured from successful claim through handoff-or-cancel selection; entering confirmation does not reset or extend it. Cleanup may outlive that decision deadline, but it retains the same slot until the channel core is fully closed. Ten seconds remains strictly inside the App SDK's 15-second default secure-admission budget. The rule applies identically to automatic and confirmation policies, so silent peers, cancellation churn, and valid-Hello placeholder churn remain globally bounded.

Incoming listener callbacks pass through one lock-protected generation ingress before any `MainActor` task is created. An inactive, paused, cancelled, stale, full, or stopped generation rejects synchronously. A slot, cleanup owner, and attempt record are installed before the potentially blocking connection claim; a generation change during that claim removes the attempt, and the returned channel cannot be reinserted or escape the cleanup receipt. Channel events are synchronously backpressured into the connection core's serial decoder, so unauthenticated input cannot create an unbounded retained event queue. Pending-summary delivery retains only the latest snapshot, delivers at most one snapshot per `MainActor` turn, and reschedules only when a newer snapshot exists. Each runtime owns and synchronously deactivates its coalescer, preventing old-generation rows from reappearing after stop or restart.

Before channel construction, Viewer creates one `ViewerAdmissionConnectionCore` and a weak ingress box. The channel's immutable callback weak-routes to that same core for its entire lifetime. On the exact TLS-ready event, the core synchronously admits one encoded Viewer `WireHello` before accepting any later phase transition. One continuous bounded frame decoder then processes all bytes: it accepts exactly one App `WireHello`, verifies opposite role and V1 negotiation, and retains the negotiated result plus terminal gate. It never transfers callback or decoder ownership.

The opaque handoff retains this same connection core and grants one consumer right; approval changes only who may continue the core, not who owns callbacks. Transfer and shutdown are serialized by one handoff owner that may reject a post-shutdown transfer and must await cleanup for every accepted handle. While pre-Hello, pending approval, or handed to the placeholder consumer, chunks and terminal channel events remain serialized through the core. Any message after the single App Hello but before the next change installs acknowledgement/session operations is a protocol violation and closes the core; raw/coalesced bytes are never stranded at a handoff boundary. The placeholder owner cancels and awaits the same core, and the connection-owner slot is released only after that cleanup completes. `viewer-multidevice-flow-control` extends that owner with hello acknowledgement, initial policy, and active session operations rather than replacing its channel handler or decoder; active-session capacity remains subject to an explicit finite owner bound.

Default policy immediately hands a valid attempt to the configured consumer. Confirmation policy retains the already reserved attempt while awaiting a decision inside the same deadline. Pending entries expose only bounded display name, Bundle ID, App version, installation-ID-derived local alias, and compatibility status. They never expose wire bytes, endpoints, certificate material, pairing code, or arbitrary transport errors.

Admission controls use the following total policy. `Require approval` is sampled only when a complete valid hello reaches the decision point; changing the setting does not alter an existing pending row. Pause cancels every claimed/pre-hello and pending attempt, rejects later arrivals until Resume, and leaves handed-off ownership untouched. Pairing refresh prepares a new listener while the old registered listener remains usable; replacement failure leaves the old listener/code active, while replacement commit cancels the old listener and every old-generation attempt not yet handed off. Shutdown cancels every not-yet-handed-off attempt and asks the handoff consumer to close its owned sessions. Timeout and Reject select cancellation; Accept selects handoff; terminal events after either result are ignored. Selection releases UI/policy ownership immediately, while the exact connection-owner slot is released only after the selected cleanup or owned session fully closes.

Accept, reject, timeout, pause, listener replacement, and shutdown each claim one terminal gate so a connection is handed off or cancelled exactly once. The foundation app uses a placeholder handoff sink that closes accepted attempts cleanly; `viewer-multidevice-flow-control` replaces that sink with the real session manager.

| Attempt state | Approval setting change | Pause | Refresh replacement | Shutdown | Deadline | Accept / Reject |
| --- | --- | --- | --- | --- | --- | --- |
| Claimed / pre-hello | Use the setting current at valid-hello decision | Select cancel; retain slot through cleanup | Keep during preparation; select cancel on replacement commit; preserve on replacement failure | Select cancel; retain slot through cleanup | Select cancel; retain slot through cleanup | Not applicable |
| Pending approval | Preserve the original pending decision | Select cancel; retain slot through cleanup | Keep during preparation; select cancel on replacement commit; preserve on replacement failure | Select cancel; retain slot through cleanup | Select cancel; retain slot through cleanup | Handoff once / cancel once; retain slot through owner cleanup |
| Handed off | No effect | No effect | No effect | Handoff owner closes session and then releases slot | No decision effect | No effect |

### 7. UI stays intentionally small

The first window contains:

- a prominent pairing section with Copy, Refresh, and Pause/Resume actions;
- a truthful transport note: `TLS encrypted; Viewer identity is not authenticated`;
- a nearby-discovery note that the pairing code and stable `vid` are visible to nearby Bonjour browsers and are not secrets;
- listener state and safe recovery actions;
- an optional `Require approval for new devices` setting, default off;
- a bounded pending-approval list with Accept and Reject;
- an empty workspace placeholder for later device and event views.

No three-column event explorer is approximated in this change. Accessibility labels, keyboard focus, selection, button states, and error text are covered by presentation-model tests; a small SwiftUI smoke test verifies the scene composes.

## Risks / Trade-offs

- **Custom narrow X.509 DER construction can be error-prone.** → Keep the encoder private and minimal, validate every emitted certificate through Security, verify signature/key correspondence, test fixed and boundary fixtures, and fail closed.
- **Bonjour registration may auto-rename or race listener readiness.** → Require both ready and exact-name registration for usable state; token every callback and retry collisions with a strict bound.
- **Connections can retain resources after a terminal decision.** → Reserve one of 32 runtime-wide slots before channel claim, apply one 10-second decision deadline, and retain the slot through asynchronous cancellation or placeholder-handoff cleanup so repeated waves cannot escape the bound.
- **Closing the window races async callbacks.** → Close generation and admission gates first, then cancel listener and attempts; ignore all stale callbacks.
- **The foundation cannot yet keep an App in an active Event session.** → Make the handoff boundary explicit and close placeholder handoffs cleanly; the next change replaces only the consumer, not identity, listener, or UI ownership.
- **The TLS design does not authenticate Viewer identity.** → Use precise UI wording and preserve the documented threat model; never imply that the public pairing code is a password.

## Migration Plan

This is the first Viewer application implementation, so there is no user-data migration. Rollback removes the Viewer project/workspace reference and the internal advertisement addition without changing SDK products or wire schemas. macOS application removal is not relied upon to delete Keychain items. TLS-only reset and the separately confirmed full Viewer-identity reset are the supported deletion paths.

## Application Metadata, Sandbox, and Privacy

The app enables App Sandbox and only `com.apple.security.network.server`. Accepted server connections remain bidirectional under that entitlement. It does not request network-client, multicast, Keychain-sharing, or application-group entitlements. Maintained development builds use the committed entitlements file and a stable team-selected Apple Development signer; Developer ID is the supported distribution alternative. Isolated unit tests and structural product inspection may explicitly override signing to ad-hoc, but that output is not persistence evidence.

The built Info.plist contains `_nearwire._tcp` in `NSBonjourServices` and the bounded English `NSLocalNetworkUsageDescription`: `NearWire advertises a local service so your iPhone apps can connect to this Mac.` Local-network denial maps to a fixed recovery category and never falls back to another transport.

Viewer owns `PrivacyInfo.xcprivacy`. It declares Device ID for App functionality, linked true, tracking false, because Viewer publishes a stable `vid` and sends its full installation ID in Viewer Hello. It declares no tracking domains. Because the approval preference uses app-local `UserDefaults`, the manifest declares only `NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1`; no unused Required Reason category is present. Packaging tests parse the source manifest, verify the built resource, inspect the signed entitlements and Info.plist, and keep this decision as a release audit rather than a permanent policy assumption.

## Open Questions

None for this change. Active admitted-session ownership, per-device flow policy, and multi-device limits are intentionally resolved by `viewer-multidevice-flow-control`.
