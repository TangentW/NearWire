# SDK Pairing Discovery

## Current Boundary

NearWire contains the repository-internal pairing-code grammar and Bonjour browser used by public `connect(code:)`. Initialization still starts no discovery, codes are not persisted, and this lower layer does not establish TLS, perform protocol admission, or transfer Events by itself.

The browser is explicitly started by its session owner. It requests TXT-enabled `_nearwire._tcp` Bonjour results in `local.`, sets `NWParameters.includePeerToPeer` to `true`, and accepts both ordinary LAN and Apple peer-to-peer paths. Peer-to-peer inclusion permits those paths; it does not force a particular physical interface.

## Host App Declarations

Every iOS App target that enables NearWire discovery must provide both declarations in its own Info.plist:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Discover and connect to the nearby NearWire Viewer used by your team.</string>
<key>NSBonjourServices</key>
<array>
  <string>_nearwire._tcp</string>
</array>
```

The usage description is an example. The host App owns its final user-facing wording. Swift Package Manager and CocoaPods cannot inject a correct host-specific description.

Network.framework Bonjour browsing does not require the direct multicast networking entitlement. Do not add `com.apple.developer.networking.multicast` for this integration. This change also adds no `PrivacyInfo.xcprivacy`: it declares no data collection and uses no required-reason API. If that reviewed decision changes, NearWire must package the same privacy resource through both SwiftPM and CocoaPods.

The local-network prompt appears only when the host later starts discovery. Creating a `NearWire` instance remains side-effect-free.

## Pairing Code

A code contains six characters from `ABCDEFGHJKMNPQRSTUVWXYZ23456789`. Parsing accepts ASCII letter case and removes only ASCII hyphens, ASCII spaces, and ASCII tab/newline whitespace. It rejects Unicode lookalikes, non-ASCII whitespace, punctuation, ambiguous characters, and raw input longer than 64 UTF-8 bytes.

The canonical code maps to exactly one instance name:

```text
7K3M9Q -> NearWire-7K3M9Q._nearwire._tcp.local.
```

Matching is case-sensitive after local code normalization. It does not accept a prefix, suffix, Bonjour conflict-renamed instance, or arbitrary service of the same type. The code remains in memory only and is omitted from supported diagnostics.

The code is public discovery metadata, not a password. It does not derive encryption keys, authenticate the Viewer, bind a certificate, or authorize event delivery.

## Viewer Discovery Discriminator

The Viewer publishes a required TXT value named `vid`. Core derives it with `CryptoKit.SHA256` over the exact UTF-8 bytes of the validated Viewer installation ID, without normalization, and encodes the first eight digest bytes as 16 lowercase hexadecimal characters.

The value is stable while the installation ID remains stable, including across pairing-code refreshes. Resetting the installation identity recomputes it. Because it is a truncated 64-bit value, distinct installations can theoretically collide. It is visible on the local discovery network and allows local correlation across advertisements.

NearWire uses different valid `vid` values only for best-effort ambiguity detection. Missing, malformed, identical, spoofed, or changed values can remain indistinguishable. Neither `vid` nor an unambiguous browser result authenticates a Viewer. The downstream TLS and protocol-admission layers still run after discovery, and the accepted V1 TLS model does not claim Viewer identity authentication.

## Selection and Lifecycle

Each complete browser update replaces the previous snapshot. The adapter rejects more than 256 raw results before conversion, reads no more than the bounded identity fields and `vid`, ignores interface observations beyond 32, and discards raw TXT data and other keys before asynchronous delivery.

Selection follows this order:

1. Two or more distinct valid exact-name `vid` values fail as ambiguous.
2. Otherwise, any exact-name result without a valid `vid` keeps discovery searching and returns no endpoint.
3. Otherwise, one valid exact registration matches; LAN and peer-to-peer appearances with the same `vid` merge.
4. No exact registration keeps discovery searching.

The result is an interface-neutral Bonjour service endpoint so Network.framework can choose the current path. Waiting invalidates the current readiness epoch. A later ready event requires a later complete result snapshot; a snapshot observed while waiting cannot replay after recovery.

Discovery is one-shot. Cancellation, policy denial, browser failure, result-limit failure, ambiguity, or a successful match completes exactly once, stops the browser when appropriate, and releases retained candidates. Errors use fixed categories and never include pairing codes, advertised names, TXT records, endpoint descriptions, interface names, raw Network.framework errors, or App event content.

## Explicit Non-Guarantees

Discovery itself does not provide persistence, internet rendezvous, background execution, retry timers, connection ownership, reconnection, TLS establishment, Viewer admission, event delivery, or authentication. Public connect and lifecycle recovery compose a fresh discovery with TLS admission and an active Event pump. The lifecycle layer, not discovery, owns the default-disabled total retry budget and host-controlled suspension policy.
