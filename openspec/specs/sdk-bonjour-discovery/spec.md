# sdk-bonjour-discovery Specification

## Purpose
TBD - created by archiving change sdk-pairing-discovery. Update Purpose after archive.
## Requirements
### Requirement: Discovery explicitly enables nearby peer-to-peer paths

The production SDK browser SHALL use the TXT-enabled Bonjour descriptor for only `_nearwire._tcp` in the local Bonjour domain with Network.framework parameters whose peer-to-peer inclusion is enabled. It SHALL NOT browse a plaintext fallback type, arbitrary service type, or internet directory.

#### Scenario: Production browser plan

- **WHEN** the production browser is constructed
- **THEN** its descriptor and parameter plan use `_nearwire._tcp`, the local domain, and peer-to-peer inclusion

### Requirement: Discovery selects only one exact Viewer

The coordinator SHALL consume complete bounded result snapshots, discard non-service and non-NearWire endpoints, deduplicate normalized logical service identities, and filter by the exact instance name derived from the pairing code. Type matching SHALL be ASCII case-insensitive and canonicalized to `_nearwire._tcp`; domain matching SHALL accept ASCII case-insensitive `local` or `local.` and canonicalize to `local.`; instance matching SHALL remain byte-exact and case-sensitive. Interface observations SHALL NOT participate in logical identity. The adapter SHALL read only a required `vid` TXT value of exactly 16 lowercase hexadecimal ASCII bytes and SHALL discard the raw TXT record and every other key before asynchronous ingress. Different valid `vid` values under one exact instance name SHALL represent distinct publisher registrations; identical values and interface-only appearances SHALL merge. Any exact registration with missing or invalid `vid` SHALL prevent selection from that snapshot, including when another registration has a valid value. Zero attributable matches SHALL continue searching, one attributable registration with no unattributed peer SHALL produce one terminal matched result, and multiple distinct valid publisher registrations SHALL produce a terminal ambiguous result. Discovery SHALL never select the first arbitrary result.

#### Scenario: Unrelated nearby Viewers

- **WHEN** a snapshot contains several NearWire services but only one exact instance name with valid `vid`
- **THEN** only the exact endpoint is selected

#### Scenario: Multiple exact identities

- **WHEN** exact-name results contain two different valid `vid` discriminator values
- **THEN** discovery terminates as ambiguous without selecting either endpoint

#### Scenario: One Viewer appears on LAN and P2P

- **WHEN** result updates expose the same canonical name, type, domain, and `vid` with different interface observations
- **THEN** they merge into one logical Viewer
- **AND** the connectable result uses an interface-neutral service endpoint

#### Scenario: Metadata is missing or malformed

- **WHEN** any exact-name result has missing or invalid `vid`, including alongside a valid registration
- **THEN** discovery remains searching and returns no endpoint from that snapshot
- **AND** a later complete snapshot in which every exact registration is attributable may be evaluated

#### Scenario: No exact match

- **WHEN** a snapshot contains only wrong names, types, or domains
- **THEN** discovery remains searching and retains no candidate endpoint

### Requirement: Discovery lifecycle is explicit and race-safe

Construction SHALL start no browser, task, timer, or permission request. One explicit `run()` SHALL transition to searching before invoking the driver and SHALL complete exactly once with one internal `DiscoveredViewer` or one safe error. A second run in any non-idle state SHALL fail without replacing the first waiter. Cancel before run SHALL become terminal without touching the driver; cancellation after driver start SHALL cancel it at most once. Ordinary waiting SHALL recover to searching only on ready. Recognized policy denial, start failure, browser failure, ambiguity, and unsolicited browser cancellation SHALL have the terminal behavior defined by the design state table. Ordered bounded callback ingress SHALL prevent late, duplicated, synchronous, or reentrant driver events from reviving terminal discovery or producing a second completion.

#### Scenario: Cancel races with exact match

- **WHEN** cancellation and an exact-match callback race
- **THEN** exactly one terminal outcome wins
- **AND** the browser is cancelled at most once

#### Scenario: Late callback

- **WHEN** a result, waiting, or failure callback arrives after a terminal outcome
- **THEN** it is ignored and retains no endpoint

#### Scenario: Waiting recovers

- **WHEN** ordinary waiting is followed by ready
- **THEN** discovery returns to searching and requires a later complete snapshot before matching

#### Scenario: Policy denial while waiting

- **WHEN** waiting reports the recognized local-network policy-denied error
- **THEN** discovery fails terminally, cancels the driver once, and requires a new explicitly created discovery after Settings change

#### Scenario: Reentrant callback during start

- **WHEN** the injected driver invokes a callback synchronously from start
- **THEN** the callback observes initialized searching state through bounded ingress
- **AND** the one-shot result still completes at most once

### Requirement: Discovery retention and diagnostics are bounded

The adapter SHALL reject more than 256 raw results before conversion, SHALL process at most 32 interfaces per result and ignore additional interface observations without discarding the result, and SHALL validate Bonjour instance, type, domain, and optional `vid` byte bounds. It SHALL synchronously discard raw TXT records, unused TXT keys, raw endpoint descriptions, and nonmatching advertised strings before asynchronous ingress. A private serial callback edge SHALL tag ready and snapshot events with a readiness epoch, treat duplicate ready callbacks while already ready as no-ops, discard snapshots received while waiting, and prevent a pre-ready snapshot from being replayed after recovery. Ingress SHALL retain at most one processing event, one coalesced latest snapshot, and one pending state or terminal event; the first terminal event SHALL be latched, discard pending nonterminal work, and prevent every later enqueue. Each converted snapshot SHALL atomically replace prior candidates. More than 256 raw results or conversion arithmetic failure SHALL publish no partial match, clear candidates, and fail safely. Individual unrelated or malformed-identity results SHALL increment a safe per-snapshot discard count and SHALL NOT fail discovery; the coordinator SHALL add accepted counts into one internal cumulative counter that saturates at `UInt64.max`. An otherwise valid exact-name result with missing or invalid `vid` SHALL instead produce one bounded unattributed marker that contains no endpoint or advertised text. Evaluation precedence SHALL be: two distinct valid discriminators produce terminal ambiguity even with unattributed markers; otherwise any unattributed marker blocks selection and keeps searching; otherwise one valid registration matches. Waiting and failure diagnostics SHALL use stable categories and fixed messages without full pairing codes, advertised names, TXT data, endpoint descriptions, interface names, raw Network.framework errors, or application content.

#### Scenario: Oversized hostile snapshot

- **WHEN** a result update contains more than 256 raw browser results, even if all normalize to one logical identity
- **THEN** discovery fails without retaining the snapshot

#### Scenario: Waiting snapshot cannot replay after ready

- **WHEN** callback order is waiting, snapshot, ready with no later snapshot
- **THEN** the waiting snapshot is discarded and discovery remains searching
- **AND** adding a later same-epoch snapshot is required before matching

#### Scenario: Callback storm

- **WHEN** result callbacks arrive faster than coordinator processing
- **THEN** only the latest bounded complete snapshot replaces the pending snapshot
- **AND** retained event and candidate counts remain within fixed bounds

#### Scenario: Oversized snapshot follows a valid match candidate

- **WHEN** a valid unmatched snapshot is followed by an oversized update
- **THEN** no partial result from the oversized update is evaluated
- **AND** all previous candidates are released before terminal failure

#### Scenario: Malformed unrelated result

- **WHEN** one bounded snapshot contains wrong-name, malformed-domain, hostile-control, or overlong unrelated results plus one valid result
- **THEN** invalid individual results increment only the safe discard count
- **AND** the valid result remains eligible without discovery-wide failure

#### Scenario: Excess interface observations do not hide identity

- **WHEN** an exact result has more than 32 interface observations
- **THEN** only the first 32 observations are processed and the remainder are ignored
- **AND** its valid `vid` remains eligible for matching or ambiguity evaluation

#### Scenario: Exact result has invalid metadata

- **WHEN** one complete snapshot contains a valid attributable exact result and another exact result with missing or malformed `vid`
- **THEN** the unattributed marker blocks endpoint selection from that snapshot
- **AND** discovery remains searching without exposing either advertisement

#### Scenario: Ambiguity takes precedence over unattributed metadata

- **WHEN** a snapshot contains two different valid exact-name `vid` values and one unattributed exact marker
- **THEN** discovery terminates as ambiguous without selecting any endpoint

#### Scenario: Browser failure contains private text

- **WHEN** the driver reports an underlying error whose description contains private data
- **THEN** the discovery error uses a fixed safe category and does not contain that description

### Requirement: Matching does not establish trust

A matched result SHALL mean only that one advertised service has the requested public instance name. It SHALL NOT imply Viewer authentication, certificate continuity, connection acceptance, session activation, or event delivery.

#### Scenario: Exact result is found

- **WHEN** discovery reports one matched endpoint
- **THEN** the later secure-connection layer must still establish TLS and complete protocol admission

Distinct valid `vid` values provide only best-effort collision detection. Missing, invalid, identical, or spoofed discriminators, and a publisher change between browsing and later DNS-SD resolution, MAY remain indistinguishable. Neither `vid`, a matching count, nor an unambiguous result SHALL authorize a security decision.

#### Scenario: Identical discriminator cannot prove one publisher

- **WHEN** two exact advertisements carry the same valid `vid`
- **THEN** discovery merges them as one logical registration
- **AND** does not claim they originated from the same Viewer

### Requirement: Matched result is operational but diagnostics are redacted

A successful run SHALL return one internal Sendable `DiscoveredViewer` containing an interface-neutral connectable `NWEndpoint` and safe logical identity. The coordinator SHALL retain neither after resuming the owner. The operational endpoint MAY contain the public instance name internally, but supported state, errors, descriptions, debug descriptions, interpolation, reflecting strings, and logs SHALL NOT expose the endpoint, pairing code, or untrusted advertised text.

#### Scenario: Later session consumes a match

- **WHEN** discovery returns a matched Viewer
- **THEN** its endpoint compiles directly as input to `SecureAppTransport.makeChannel(endpoint:)`
- **AND** discovery retains no duplicate endpoint or continuation

#### Scenario: Hostile advertised name reaches diagnostics

- **WHEN** nearby names contain Unicode lookalikes, bidi controls, CR/LF, or other controls
- **THEN** they are discarded without appearing in any safe summary or error formatting

### Requirement: Host App declares local-network discovery usage

English SDK integration documentation SHALL require the host App to provide `NSLocalNetworkUsageDescription` and an `NSBonjourServices` array containing `_nearwire._tcp`. It SHALL state that SwiftPM and CocoaPods cannot supply the host-specific usage description, that Network.framework Bonjour browsing does not require the direct-multicast entitlement, and that this change adds no privacy manifest because it introduces neither declared data collection nor a required-reason API. If that reviewed privacy decision changes, equivalent SwiftPM and CocoaPods resource packaging SHALL be required.

The documentation SHALL define `vid` derivation, stability, reset behavior, local linkability, best-effort ambiguity limits, and non-authentication semantics.

#### Scenario: Integrator prepares an App target

- **WHEN** an engineer follows the SDK discovery documentation
- **THEN** both required Info.plist declarations and the reviewed entitlement/privacy-manifest decisions are explicit
