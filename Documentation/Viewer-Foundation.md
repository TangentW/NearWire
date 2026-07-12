# NearWire Viewer Foundation

## Scope

The Viewer foundation is the first native macOS application layer. It owns the main window, persistent Viewer identities, ephemeral pairing codes, Bonjour publication, mandatory-TLS listener startup, and bounded admission through one App Hello. It intentionally does not own active Event transfer, multi-device workspaces, local event history, search, export, or performance charts. Those capabilities are added by later Viewer changes without replacing the connection core established here.

The user-visible application and bundle name is `NearWire`. The manually maintained project, target, and Swift module are named `NearWireViewer` so they do not collide with the iOS SDK module.

## Build and Run

Open `NearWire.xcworkspace` or `Viewer/NearWireViewer.xcodeproj` in Xcode 16 or later, select the internal Apple Development team once, and run the `NearWireViewer` scheme. The target supports macOS 13 or later and compiles in Swift 5 language mode. It links the repository-local `NearWireCore` product and Apple frameworks only. Maintained internal updates must keep the same Apple Development signer; Developer ID is the supported alternative for distributed builds. Ad-hoc signing is reserved for isolated tests and structural inspection because its changing code requirement cannot preserve non-interactive login-Keychain access across rebuilds.

The application has one supported main window. Opening it starts identity preparation and listener publication automatically. Closing the last window synchronously closes publication, admission, and handoff transfer, then waits at most one second for one owned cleanup receipt before terminating. That receipt covers claim-in-progress work, attempts already cancelling because of policy or timeout, late returned channels, and accepted placeholder handoffs. A timed-out wait never reopens admission and does not discard cleanup ownership. There is no menu-bar agent, daemon, launch-at-login behavior, or second listener window.

### Stable-Signer Update Gate

The cross-update Keychain gate is one conditional XCTest, not a separate script. It requires two valid, unrelated code-signing identities. List the available identities with `security find-identity -v -p codesigning`, then set `IDENTITY_A` and `IDENTITY_B` to their full SHA-1 values and set `TEAM_A` and `TEAM_B` to the corresponding team identifiers. The two identities must produce different designated requirements.

Run the following commands in one shell and in the shown order. Each test phase uses a separate DerivedData directory, a distinct signed `CFBundleVersion`, an explicit operator build identifier, and one token-scoped state root inside the production bundle's test container. Xcode's app-hosted test entitlement grants the unrelated test product read-only fixture access; only the stable create and verify products write or remove that state. The four `NEARWIRE_SIGNER_PROBE_*` build settings expand into reserved Info.plist fields, binding the phase configuration to the signed app host instead of relying on shell-environment forwarding. Normal builds expand them to empty strings. The test records and compares the signed host Code Directory hash, bundle version, product path, team identifier, signing-certificate hash, and designated requirement. Phase A and phase B must have the same signer fingerprint but distinct signed builds, while the denial phase must have an unrelated designated requirement.

```sh
set -e
STATE_ROOT="$HOME/Library/Containers/com.nearwire.viewer/Data/tmp/nearwire-viewer-stable-signer-probe"

xcodebuild test -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-signer-a CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY_A" DEVELOPMENT_TEAM="$TEAM_A" CURRENT_PROJECT_VERSION=1001 NEARWIRE_SIGNER_PROBE_PHASE=create NEARWIRE_SIGNER_PROBE_TOKEN=release-candidate NEARWIRE_SIGNER_PROBE_BUILD_ID=stable-a NEARWIRE_SIGNER_PROBE_STATE_ROOT="$STATE_ROOT" ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests/testStableSignerUpdateBoundaryProbe

xcodebuild test -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-signer-unrelated CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY_B" DEVELOPMENT_TEAM="$TEAM_B" CURRENT_PROJECT_VERSION=2001 NEARWIRE_SIGNER_PROBE_PHASE=deny NEARWIRE_SIGNER_PROBE_TOKEN=release-candidate NEARWIRE_SIGNER_PROBE_BUILD_ID=unrelated NEARWIRE_SIGNER_PROBE_STATE_ROOT="$STATE_ROOT" ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests/testStableSignerUpdateBoundaryProbe

touch "$STATE_ROOT/release-candidate/deny-complete"

xcodebuild test -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-signer-b CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY_A" DEVELOPMENT_TEAM="$TEAM_A" CURRENT_PROJECT_VERSION=1002 NEARWIRE_SIGNER_PROBE_PHASE=verify NEARWIRE_SIGNER_PROBE_TOKEN=release-candidate NEARWIRE_SIGNER_PROBE_BUILD_ID=stable-b NEARWIRE_SIGNER_PROBE_STATE_ROOT="$STATE_ROOT" ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests/testStableSignerUpdateBoundaryProbe
```

The create phase stores an isolated installation identity and TLS identity and proves private-key signing. The unrelated phase separately checks production load and both reset APIs, exact reads of both generic-password records, exact private-key lookup and signing use, and exact deletion of all four record classes. Only after that `xcodebuild test` succeeds does the operator create the non-sensitive completion marker required by verify. The final same-signer build proves that the original installation ID, certificate, and signing key remain intact before exercising TLS-only and full reset. A normal ad-hoc test run leaves the signed phase field empty and reports this one packaging test as skipped.

## Pairing and Nearby Discovery

Each listener generation creates a six-character code from `ABCDEFGHJKMNPQRSTUVWXYZ23456789` with `SecRandomCopyBytes` and unbiased rejection sampling. The code maps to the Bonjour instance `NearWire-<code>` under `_nearwire._tcp` in `local.`. TXT data contains only `vid`, the stable bounded discriminator derived from the Viewer installation ID.

The code is memory-only. NearWire does not store it in UserDefaults, Keychain, session data, logs, or analytics. It enters the system clipboard only when the user chooses Copy.

The UI reports a code as listening only after both the listener and the exact Bonjour registration are ready. If the system registers a renamed instance, NearWire cancels that candidate and tries a fresh code at most three times. Refresh prepares a replacement while the existing registered listener remains usable. The old publication and its unhanded admission attempts are cancelled only after the replacement commits; a replacement failure leaves the old code active.

Pairing codes and `vid` values are public nearby-discovery identifiers. They are visible to devices that can browse the Bonjour service and are not passwords or proof of Viewer identity.

## Installation and TLS Identity

Viewer stores two independent identities through `SecItem` in the per-user macOS login Keychain:

- a random installation UUID in generic-password account `installation-id` under service `com.nearwire.viewer.identity.v1`;
- TLS metadata in account `tls-metadata`, a permanent nonextractable P-256 private key tagged `com.nearwire.viewer.tls-key.v1`, and the metadata-referenced certificate.

Items do not synchronize and use no Keychain-sharing entitlement. The login Keychain protects sensitive operations with the maintained app's stable code-signing requirement. Reads, existence checks, exact identity assembly, and deletes use an `LAContext` with interaction disabled so automatic startup and recovery fail closed instead of displaying an unexpected Keychain prompt. There is no broad default-Keychain identity fallback or arbitrary-app ACL. Private-key creation requests permanent and sensitive storage. Reload validates the exact tagged P-256 key, proves nonexportability, and supports a real signing operation; it does not depend on permanent/sensitive values that login-Keychain `SecKey` references do not reliably expose. Certificate metadata records the persistent certificate reference, serial, certificate hash, and public-key hash. The reference is resolved through `kSecMatchItemList`; reads and deletion then require the fixed profile, self-signature, exact private-key correspondence, and every stored digest to match. Missing or mismatched metadata never authorizes a broad label search or deletion of an unrelated certificate. Before release, the update-boundary integration gate must prove reuse by a second build with the same signer and denial to an unrelated signer.

The self-signed leaf uses P-256, ECDSA with SHA-256, a fixed non-identifying common name, a positive 16-byte serial, five minutes of not-before skew, and a 3,650-day lifetime. Its DER validity uses UTCTime through 2049 and GeneralizedTime from 2050 onward. Its only extensions are critical CA=false, critical digital-signature key usage, and noncritical server-auth extended key usage. It has no SAN or network-fetching extension.

Every load verifies the fixed DER profile, current time, at least 30 days of remaining validity, self-signature, private-key correspondence, and anchor-only Basic X.509 trust. An invalid or near-expiry owned identity receives one stop-before-repair recreation attempt. Failure leaves publication disabled.

`Reset TLS Identity` removes only the exact owned TLS records and preserves the installation ID. `Reset All Viewer Identity` is separately confirmed and also replaces the installation ID. A partial or unverifiable explicit reset fails closed. Pairing refresh never rotates either persistent identity.

TLS 1.3 encryption and integrity are mandatory, but V1 does not authenticate the Viewer to the App. The App connection-local trust callback accepts a valid presented self-signed leaf without pinning it. The fixed UI wording is therefore `TLS encrypted; Viewer identity is not authenticated.` There is no plaintext fallback.

## Admission Policy and Limits

The default policy automatically accepts a compatible App Hello. The user may enable approval for new devices; the setting is sampled when a complete valid Hello reaches its decision point, so changing the setting does not retroactively accept an existing pending row.

One runtime-wide connection-owner budget covers both the active listener and a replacement listener:

- at most 32 claimed, pre-Hello, approval-pending, cancelling, or placeholder-owned connections;
- one 10-second monotonic decision deadline from claim through handoff-or-cancel selection;
- reservation before the incoming wrapper is claimed;
- exact one-time release before the corresponding cleanup completion is published, after asynchronous channel or placeholder-handoff cleanup completes.

The 33rd connection is rejected before channel construction, decoding, deadline work, cleanup work, or UI state, even when all 32 earlier connections are terminal but still cleaning up. Silent and partial-Hello peers reach a terminal decision at the original deadline and retain their existing slot only until cancellation actually completes. Pause cancels claimed and pending attempts and rejects later arrivals while leaving already handed-off ownership alone.

Incoming listener callbacks first cross a synchronous generation gate. Stale, paused, stopped, or over-capacity arrivals are rejected before any `MainActor` task is created, and a claim that finishes after its generation was cancelled cannot reinsert itself. Channel events are synchronously backpressured into the connection core's serial decoder, avoiding a second unbounded input queue. Pending-device UI delivery keeps only the latest snapshot, delivers one snapshot per main-actor turn, and is deactivated with its runtime generation so stale rows cannot return after stop or restart.

One connection core owns the secure channel callback, Viewer Hello send, continuous frame decoder, negotiation result, and terminal gate. Approval transfers only an opaque consumer right that retains the same core. The multi-device owner now extends that same core with acknowledgement, policy, and active session operations; it does not install a second callback or decoder.

## Recovery

Viewer presents only fixed recovery categories. It never renders `NWError`, OSStatus, endpoints, interface names, wire bytes, certificate material, Keychain selectors, pairing codes from errors, or untrusted App content as diagnostics.

- Identity failure: Retry, Reset TLS Identity, or separately confirmed full reset.
- Pairing randomness failure: Retry.
- Local-network permission failure: allow local network access in System Settings, then Retry.
- Listener or registration failure: check network availability, then Retry.

No recovery path starts a plaintext, identity-free, or alternate listener.

## Sandbox and Privacy

The application sandbox contains only the incoming network-server entitlement required by this foundation. It does not request network-client, multicast, Keychain-sharing, application-group, or background-service entitlements.

The built Info.plist advertises `_nearwire._tcp` and explains local-network use. `PrivacyInfo.xcprivacy` declares linked Device ID for App functionality with tracking disabled because `vid` is published and the complete installation ID is sent in Viewer Hello. It contains no tracking domains. The app-local approval preference uses `UserDefaults`, so the manifest declares only the required `NSPrivacyAccessedAPICategoryUserDefaults` reason `CA92.1`; it contains no unused Required Reason category.

## Active Session Boundary

`viewer-multidevice-flow-control` consumes the existing opaque handoff and adds active device sessions, Hello acknowledgement, requested and effective directional rates, bounded queues, telemetry, and device isolation without replacing the identity store, listener generation model, secure-channel callback owner, or continuous decoder introduced here. See [Viewer-MultiDevice-Flow-Control.md](Viewer-MultiDevice-Flow-Control.md).
