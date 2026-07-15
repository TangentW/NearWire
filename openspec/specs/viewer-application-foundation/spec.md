# viewer-application-foundation Specification

## Purpose
TBD - created by archiving change viewer-application-foundation. Update Purpose after archive.
## Requirements
### Requirement: Viewer installation and TLS identities persist separately

Viewer SHALL store one random installation identifier and one self-signed TLS `SecIdentity` under separate versioned selectors in the standard per-user macOS login Keychain, using `SecItem`, synchronization false, `kSecUseDataProtectionKeychain=false`, and no Keychain-sharing entitlement. Maintained Viewer builds SHALL use one stable Apple Development signing identity for internal updates or one stable Developer ID identity for distributed updates; an ad-hoc build SHALL NOT be treated as proof of cross-update Keychain persistence. Keychain reads, existence checks, exact identity queries, and deletes SHALL use an authentication context with interaction disabled and SHALL fail closed rather than prompting or broadening the Keychain search during automatic startup or recovery. Both identities SHALL be created or loaded before a listener or pairing code exists. The installation identifier and valid TLS identity SHALL remain stable across window/runtime, pairing-code refreshes, and updates signed by the same supported signer. An unrelated signer SHALL NOT gain non-interactive read, signing, or deletion access. Private-key creation SHALL request permanent and sensitive P-256 storage. Reload SHALL select only the exact Viewer application tag and key class/type, validate P-256 size, and prove actual nonexportability and signing use; it SHALL NOT require login-Keychain `SecKey` reference attributes that are not reliably readable. Generic-password installation and TLS-metadata items SHALL use exact service/account selectors. The certificate SHALL be selected by the metadata-owned persistent reference through `kSecMatchItemList` and cross-checked by fixed profile, self-signature, serial, certificate hash, public-key hash, and exact private-key correspondence. The TLS private key and certificate material SHALL NOT appear in logs, errors, reflection, clipboard, exported data, or UI.

This change SHALL deliver the app-hosted A/unrelated/B update-boundary XCTest and its fail-fast operator recipe. When the implementation host has no valid signing identities, execution evidence MAY be deferred to the repository's final `release-hardening` change, but the gate SHALL remain mandatory and the final NearWire completion audit SHALL fail until the supported-signer sequence passes.

The self-signed leaf SHALL use the fixed X.509 v3 profile: P-256 SPKI, ECDSA-with-SHA256 signature, positive nonzero random serial no longer than 16 octets, fixed non-identifying `CN=NearWire Viewer Local TLS` subject/issuer, five-minute not-before skew, 3,650-day lifetime, canonical UTCTime through 2049 and GeneralizedTime from 2050 onward, critical CA=false, critical digital-signature key usage, noncritical server-auth extended key usage, and no SAN or network-fetching extension. Load SHALL strictly parse both time forms and validate profile, self-signature, key correspondence, anchor-only Basic X.509 trust, current validity, and at least 30 days remaining. Invalid or near-expiry identity SHALL receive only one stop-before-repair renewal attempt.

Identity loading SHALL repair one partial or mismatched owned record at most once and otherwise fail closed. Missing metadata SHALL NOT authorize deletion of an arbitrary certificate. Identity failure SHALL prevent Bonjour publication and expose only fixed safe recovery text. Explicit TLS reset SHALL stop listener/admission, delete only the exact owned TLS metadata reference, certificate, and private-key tag, preserve installation ID, create a new identity, and restart. A separately confirmed full Viewer-identity reset SHALL delete both exact generic-password accounts and exact TLS items before regeneration. Partial deletion/recreation SHALL fail closed. Neither reset SHALL silently downgrade TLS or describe the connection as authenticated.

#### Scenario: Viewer restarts normally

- **WHEN** valid installation and TLS identity records already exist
- **THEN** Viewer reuses both identities and creates no replacement key or certificate

#### Scenario: Stable-signed Viewer updates

- **WHEN** a newer maintained Viewer build is signed by the same supported signing identity
- **THEN** it non-interactively reuses the existing installation and TLS identities and performs a real private-key signing operation
- **AND** a build signed by an unrelated identity cannot read, use, reset, or delete those records

#### Scenario: Identity initialization fails

- **WHEN** Security or Keychain cannot produce a valid matching `SecIdentity`
- **THEN** no listener or Bonjour service starts
- **AND** the UI offers fixed Retry and Reset TLS Identity actions without exposing private material or raw system diagnostics

#### Scenario: Pairing code refreshes

- **WHEN** the user refreshes the pairing code
- **THEN** neither persistent installation identity nor TLS identity rotates

#### Scenario: TLS identity approaches expiry

- **WHEN** a loaded certificate has less than 30 days remaining or is outside its validity window
- **THEN** Viewer stops before performing one bounded owned-item renewal
- **AND** another failure leaves publication disabled

#### Scenario: Foreign Keychain item shares human-readable text

- **WHEN** repair or reset encounters an item that does not match the exact owned selectors and metadata
- **THEN** Viewer preserves that item and fails closed rather than broadening deletion

### Requirement: Pairing and Bonjour publication are exact and ephemeral

Each listener generation SHALL generate one six-character pairing code from the canonical 31-character alphabet using `SecRandomCopyBytes` with unbiased rejection sampling. The code SHALL exist only in bounded runtime/UI state and optional user-initiated clipboard content. It SHALL NOT be persisted or emitted to logs, errors, analytics, Keychain, or session data.

After identity readiness, Viewer SHALL create one mandatory-TLS, peer-to-peer-enabled listener advertising the exact `NearWire-<code>` instance under `_nearwire._tcp` in the local domain. TXT data SHALL contain only one valid `vid` derived from the stable Viewer installation ID. The code SHALL become usable/presented as listening only after listener readiness and exact-name service registration. Registration rename or collision SHALL cancel the misleading publication and retry with a fresh code under a finite bound; exhaustion SHALL fail safely.

#### Scenario: Listener becomes available

- **WHEN** identities, listener readiness, and exact service registration all succeed
- **THEN** the UI presents the canonical pairing code with Copy and Refresh actions
- **AND** discovery publishes only the expected instance, type, domain, and `vid`

#### Scenario: Bonjour auto-renames the service

- **WHEN** Network.framework registers a different instance name
- **THEN** Viewer does not present the old code as usable
- **AND** it cancels that listener and performs only the bounded fresh-code retry policy

#### Scenario: User refreshes the code

- **WHEN** a usable listener receives Refresh Pairing Code
- **THEN** a replacement publication uses a fresh code and the same persistent identities
- **AND** already handed-off connections are not cancelled by ordinary refresh

### Requirement: Secure listener keeps Bonjour and raw transport internal

The repository-internal secure Viewer listener SHALL accept one validated Bonjour advertisement before start and SHALL install it on the same TLS-only `NWListener`. It SHALL report bounded ready, exact registration, registration mismatch/removal, incoming connection, failure, and cancellation events while hiding raw listener, connection, endpoint descriptions, and underlying Network errors. Cancellation SHALL atomically prevent a racing incoming connection from being claimed.

#### Scenario: Advertised secure listener starts

- **WHEN** Viewer supplies a valid transport identity and advertisement
- **THEN** one listener uses TLS 1.3, NearWire ALPN, TCP, peer-to-peer routing, and that Bonjour service
- **AND** no identity-free, plaintext, or raw-listener path is introduced

#### Scenario: Listener cancellation races an incoming connection

- **WHEN** cancellation closes admission before an incoming wrapper is claimed
- **THEN** the connection is cancelled and cannot be handed to Viewer application code

### Requirement: New-App admission is default-automatic, optional, and bounded

Viewer SHALL claim each incoming TLS connection at most once and decode only the bounded pre-session Control sequence needed to obtain one App `WireHello`. It SHALL reject wrong roles, incompatible protocol/codec/capability input, malformed or oversized frames, unexpected message types, timeout, and shutdown before creating UI state. A valid attempt SHALL produce a safe bounded App summary and one opaque handoff without exposing raw Network.framework values.

Viewer SHALL maintain one runtime-wide capacity of exactly 32 connection-owner slots shared by current and replacement listener generations. It SHALL reserve a slot before claiming an incoming wrapper or starting per-connection work. The slot SHALL remain reserved through TLS/channel readiness, claimed/pre-hello decoding, optional pending approval, asynchronous cancellation completion, and placeholder-handoff cleanup. A 33rd connection SHALL be cancelled without creating a channel, decoder Task, deadline Task, cleanup task, or UI row, including while all earlier attempts are already terminal but still cleaning up. Every claimed attempt SHALL use one monotonic 10-second decision deadline from claim through handoff-or-cancel selection; completing hello or entering approval SHALL NOT reset or extend it. Cleanup MAY outlive the decision deadline but SHALL retain the exact slot until its connection core and late-returned channel ownership are fully closed. Every connection SHALL release the exact slot once.

Incoming listener callbacks SHALL synchronously pass through one active-generation ingress before any `MainActor` task is created. Inactive, paused, cancelled, stale, full, and stopped generations SHALL reject at that edge. Viewer SHALL install the slot, attempt record, and cleanup owner before the potentially blocking connection claim and SHALL prevent a claim completing after generation cancellation or pause/resume from reinserting itself or escaping shutdown cleanup. Channel events SHALL be synchronously backpressured through the connection core's serial decoder rather than retained in an unbounded event queue. Pending-summary publication SHALL retain only the latest snapshot, deliver at most one snapshot per `MainActor` turn, and synchronously deactivate its runtime generation during stop so stale rows cannot reappear after stop or restart.

One Viewer admission connection core SHALL be created before channel construction and SHALL remain the immutable channel-callback and continuous frame-decoder owner for that connection. On TLS ready it SHALL synchronously admit exactly one valid Viewer Hello. It SHALL decode exactly one App Hello, verify opposite role and compatible V1 negotiation, retain the negotiated result and terminal gate, and serialize all later bytes/terminal input without transferring callback or decoder ownership. Approval handoff SHALL transfer one consumer right retaining the same core. Input beyond App Hello before later session operations attach SHALL fail safely. The placeholder handoff owner SHALL cancel and await that same core; the next change SHALL extend it rather than replace its callback owner.

The default setting SHALL automatically hand valid attempts to the configured consumer. When confirmation is enabled, Viewer SHALL retain the already bounded attempt until Accept, Reject, or its original deadline. Approval policy SHALL be sampled when one complete valid hello reaches its decision point; changing the setting SHALL NOT alter an existing pending row. Pause SHALL cancel all claimed/pre-hello and pending attempts, reject later arrivals until Resume, and SHALL NOT cancel handed-off ownership. Listener replacement SHALL leave the registered old listener and its attempts active during preparation; replacement failure SHALL preserve them, while replacement commit SHALL cancel every old-generation attempt that is not handed off. Shutdown SHALL cancel every non-handed-off attempt and atomically close handoff transfer before awaiting accepted-handle cleanup. One manager-owned registry SHALL retain claim-in-progress, already-cancelling, handed-off, and late-returned channel cleanup until completion and SHALL release the exact slot before publishing cleanup completion. Accept, reject, timeout, pause, replacement commit, and shutdown SHALL select exactly one handoff-or-cancel terminal outcome.

This change's placeholder handoff owner SHALL close accepted handoffs cleanly; active hello acknowledgement, flow policy, multi-device session ownership, and Event transfer SHALL be implemented by the next change.

#### Scenario: Default automatic admission

- **WHEN** a valid App hello arrives while approval is disabled and admission is not paused
- **THEN** the attempt is handed to the configured consumer exactly once without a confirmation prompt

#### Scenario: Confirmation is required

- **WHEN** a valid App hello arrives while approval is enabled
- **THEN** one bounded pending row presents only safe App metadata
- **AND** Accept hands off once while Reject or timeout cancels once

#### Scenario: Pending bound is full

- **WHEN** 32 slots are occupied by any mixture of silent, partial-hello, approval-pending, cancelling, and placeholder-owned connections and another connection reaches admission
- **THEN** the additional connection is cancelled before channel claim or per-connection work
- **AND** no existing slot is evicted

#### Scenario: Listener ingress races generation cancellation

- **WHEN** an incoming connection claim is in progress while its listener generation is cancelled or admission is paused and resumed
- **THEN** the attempt cannot reinsert itself or reach handoff
- **AND** a pre-admission burst creates neither unbounded `MainActor` tasks nor more than 32 claimed attempts

#### Scenario: Silent peer reaches the deadline

- **WHEN** an automatic-policy or confirmation-policy peer sends no complete hello for 10 seconds after claim
- **THEN** its channel is cancelled and its exact slot is released

#### Scenario: Viewer channel becomes ready

- **WHEN** one admission connection reaches mandatory-TLS ready state
- **THEN** its permanent core admits exactly one Viewer Hello and keeps the only decoder/callback ownership

#### Scenario: Approval handoff occurs

- **WHEN** a valid negotiated App Hello is automatically or manually accepted
- **THEN** one opaque handle retaining the same connection core is handed to the consumer
- **AND** no callback, decoder, raw byte, or terminal gate is transferred to a second owner

#### Scenario: Approval setting changes with a pending row

- **WHEN** a valid hello is already pending approval and the setting is disabled
- **THEN** that row retains its original explicit Accept or Reject decision

#### Scenario: Admission is paused

- **WHEN** Pause New Devices is active
- **THEN** claimed/pre-hello and pending attempts are cancelled and later arrivals are rejected before handoff
- **AND** already handed-off connections remain outside the pause action

#### Scenario: Pairing listener replacement fails

- **WHEN** a replacement listener cannot reach exact registered state
- **THEN** the old registered listener, code, and nonterminal attempts remain active

#### Scenario: Pairing listener replacement commits

- **WHEN** a replacement listener reaches exact registered state
- **THEN** old-generation claimed/pre-hello and pending attempts are cancelled
- **AND** handed-off ownership is preserved

### Requirement: Foundation UI is truthful and recovery-oriented

The main window SHALL show pairing/listener status, Copy, Refresh, Pause/Resume, the approval setting, pending approval actions, fixed identity/listener recovery actions, one bounded Devices strip, memory-Session import/export actions, and Timeline/Inspector/Composer visibility controls. It SHALL NOT present a Sources or recorded-session sidebar, local-database settings, database status, cleanup, retry, capacity, retention, or durable-recording state. It SHALL label transport as `TLS encrypted; Viewer identity is not authenticated` and SHALL state that the pairing code and stable `vid` are visible to nearby Bonjour browsers.

All controls SHALL expose accessibility labels, help, keyboard focus, and disabled states derived from the single application model. User-visible and diagnostic errors SHALL use closed safe categories and SHALL NOT include pairing code, identity material, endpoint/interface descriptions, wire bytes, App content, imported Event content, or arbitrary system error text.

#### Scenario: Listener is ready

- **WHEN** the exact service is registered
- **THEN** pairing, Device, memory-Session, and available workspace actions use truthful enabled states
- **AND** no database lifecycle or storage setting is presented

### Requirement: Viewer application metadata and privacy match local discovery

Viewer SHALL enable App Sandbox with both the network-server and network-client entitlements
required by its Network.framework listener and accepted-connection path. It SHALL NOT request
multicast, Keychain-sharing, application-group, or background-service entitlements. The built
Info.plist SHALL list `_nearwire._tcp` in `NSBonjourServices` and SHALL contain the English
local-network usage description `NearWire advertises a local service so your iPhone apps can
connect to this Mac.` Local-network denial SHALL produce a fixed recoverable failure and no
alternate or plaintext listener.

Viewer SHALL package its own valid `PrivacyInfo.xcprivacy` declaring linked Device ID for App
functionality and tracking false because it publishes stable `vid` and sends its installation ID
in Viewer Hello. It SHALL omit tracking domains and SHALL declare
`NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1` for the app-local approval
preference while omitting unused Required Reason API categories. Build evidence SHALL inspect the
final Info.plist, signed entitlements, and packaged privacy resource.

#### Scenario: Built Viewer metadata is audited

- **WHEN** the committed Viewer application is built and signed for macOS
- **THEN** its product contains the local-network description, NearWire Bonjour service, exact
  sandbox server and client entitlements, and Viewer privacy manifest
- **AND** no multicast, Keychain-sharing, app-group, tracking, or unused Required Reason
  declaration is present beyond the required app-local UserDefaults reason

#### Scenario: Sandboxed Viewer accepts an iPhone flow

- **WHEN** a discovered iPhone App opens a connection to the sandboxed Viewer listener
- **THEN** macOS permits the accepted Network.framework flow to reach the Viewer
- **AND** the connection proceeds through the existing mandatory TLS and admission path

#### Scenario: Local-network access is unavailable

- **WHEN** listener startup reports local-network denial or unavailability
- **THEN** Viewer shows fixed recovery guidance and publishes no fallback service

### Requirement: Viewer admission accepts the production SDK Event-size offer

Viewer admission SHALL decode an otherwise valid App Hello that advertises the exact maximum
deterministic Event-record size calculated for 1 MiB canonical content. Viewer SHALL advertise and
enforce the same production capacity by default, retain existing bounded admission ownership, and
continue to the normal automatic or approval handoff. It SHALL NOT allocate an offered-size Event
buffer during Hello decoding. Negotiation with an explicitly smaller peer SHALL still select the
smaller value.

#### Scenario: Production SDK Hello reaches handoff

- **WHEN** Bonjour, TCP, and TLS succeed and App sends a valid production Hello whose Event-record
  offer includes 1 MiB content plus its envelope
- **THEN** Viewer decodes and negotiates the Hello instead of cancelling the secure connection
- **AND** the effective Event limit carries the exact production record maximum
- **AND** the attempt reaches its configured automatic or approval handoff

#### Scenario: Smaller peer remains conservative

- **WHEN** a valid peer advertises less than the Viewer production Event-record capacity
- **THEN** negotiation selects the smaller peer offer
- **AND** Viewer does not widen the resulting active session

### Requirement: Viewer is a native multi-window macOS application

The repository SHALL contain a manually maintained `Viewer/NearWireViewer.xcodeproj` with a native SwiftUI application named `NearWire`, module name `NearWireViewer`, one unit-test target, macOS 13 deployment, and Swift 5 language mode. It SHALL use the repository-local `NearWireCore` product and Apple frameworks only. It SHALL NOT add a nested package manifest, podspec, project generator, menu-bar agent, daemon, root Swift Package dependency, or local Session database.

The application SHALL expose one singleton main Event window, one singleton auxiliary Performance window, one process-lifetime memory Session, and no supported second-listener window or historical Source browser. Opening the application SHALL start one runtime generation without a Start button. Either window MAY remain open or reopen while reusing that exact runtime generation. Closing the last window or terminating the application SHALL synchronously close admission, stop publication/listening, cancel pending attempts, clear received memory content, and await one idempotent cleanup receipt for at most one second without leaving a hidden listener. Expiry of that wait SHALL NOT reopen admission.

#### Scenario: Main and Performance windows open and close

- **WHEN** the NearWire main window starts one successful runtime and the operator opens Performance
- **THEN** exactly one Viewer runtime generation and one memory Session serve both singleton windows
- **AND** closing the last window stops that generation and clears its Session without a database, menu-bar item, daemon, or historical Source lifetime

### Requirement: Viewer follows the system language and supports one manual language preference

The Viewer SHALL provide complete English and Simplified Chinese localization for Viewer-owned UI. A fresh or invalid preference SHALL use System and resolve from the current macOS language. Viewer Settings SHALL offer exactly System, English, and Simplified Chinese. A manual choice SHALL persist as one bounded enum value across launches and apply immediately to the main Event window, singleton Performance window, Settings, and inherited presentation surfaces without restarting the runtime, listener, working Session, or window identity.

System mode SHALL react to relevant macOS locale-change publication. Any Chinese system locale, including Traditional Chinese locales, SHALL resolve to the supported Simplified Chinese presentation; every non-Chinese system locale SHALL resolve to English. English and Simplified Chinese manual choices SHALL use explicit supported locales. Missing or malformed preference data SHALL safely fall back to System; a missing translation SHALL fall back to the English development value. The preference SHALL contain no Event, Device, identity, or Session content.

#### Scenario: Viewer starts without a language preference

- **WHEN** the Viewer launches with no valid stored language value and macOS resolves to Simplified Chinese
- **THEN** all Viewer-owned UI in both supported windows is presented in Simplified Chinese
- **AND** runtime and Session startup are identical to an English launch

#### Scenario: macOS uses Traditional Chinese

- **WHEN** Viewer uses System and the current macOS preferred language is a Traditional Chinese locale
- **THEN** every Viewer-owned surface uses the supported Simplified Chinese localization
- **AND** Settings continues to show System as the selected preference

#### Scenario: Operator selects English while both windows are open

- **WHEN** the main Event window and Performance window currently use Simplified Chinese and the operator selects English in Settings
- **THEN** both windows and later-presented sheets switch to English without process or runtime restart
- **AND** Event selection, filters, Device scope, chart scope, Session state, and active connections remain unchanged

#### Scenario: Stored preference is malformed

- **WHEN** the stored language raw value is unknown or malformed
- **THEN** Viewer uses System and exposes System as the selected Settings choice
- **AND** it neither crashes nor invents a fourth language state

### Requirement: Viewer localization stays inside the Viewer product boundary

Viewer SHALL localize its own labels, guidance, validation, errors, confirmations, menus, tooltips, state descriptions, formatted presentation, and accessibility text. It SHALL display App-provided names, Bundle IDs, nicknames, pairing codes, Event types, Event content, JSON keys/values, UUIDs, and other received values verbatim. Localization SHALL NOT mutate protocol values, wire behavior, query ordering, Session JSON, exports, logs, SDK APIs, NearWireUI, or Demo UI.

#### Scenario: Received content resembles a localization key

- **WHEN** an App sends an Event type or content string identical to Viewer product text
- **THEN** Timeline and Inspector display the received value byte-for-byte as decoded
- **AND** only surrounding Viewer-owned labels follow the selected language
