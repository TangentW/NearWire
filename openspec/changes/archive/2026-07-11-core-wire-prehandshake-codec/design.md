# Core Wire Pre-Handshake Codec Design

## Context

NearWire's raw `WireMessage`, `WireMessageCodec`, and `WireMessagePayload` remain module-internal so external code cannot invent message types or bypass phase checks. `WireSessionCodec` is repository SPI, but it is intentionally constructed from a completed `WireNegotiationResult`. The first hello must cross the wire before that result exists.

This change fills only that bootstrap gap. It does not own a byte channel or handshake lifecycle. A later SDK session actor will frame transport chunks, pass complete frames into this codec, switch over a sealed typed pre-handshake result, exchange hello, call `WireNegotiator`, validate the Viewer acknowledgement with the negotiated `WireSessionCodec`, and own timeouts and cancellation.

## Goals and Non-Goals

Goals:

- Provide a closed repository SPI for the V1 pre-handshake phase.
- Reuse the same frame, deterministic JSON, phase, lane, payload, and size validation as negotiated sessions.
- Reject malformed or out-of-phase input before it can become a typed hello.
- Keep all raw message and payload-extension points sealed inside NearWireTransport.
- Keep the codec synchronous, immutable, Sendable, platform-neutral, and free of retained application content.

Non-goals:

- Channel creation, TLS, discovery, process lease ownership, timeout, retry, or cancellation.
- Viewer approval or rejection policy.
- Hello negotiation, acknowledgement creation or validation, flow-policy negotiation, or active session state.
- Public SDK methods, UI, persistence, logging, telemetry, or event transfer.
- A future-version bootstrap registry. Only the registered V1 bootstrap schema exists.

## Decisions

### 1. Use one fixed V1 bootstrap envelope

`WirePreHandshakeCodec` has no caller-selectable wire version. It emits and accepts envelope version V1 because V1 is the only registered bootstrap message schema. The hello payload may advertise a broader supported interval, but that interval influences the later negotiation result, not the schema used to carry the initial hello.

A future wire version may replace this rule only by adding an explicit bootstrap codec registry and compatibility design. It must not label V1 message bytes as an unimplemented future envelope version.

### 2. Keep the message set closed

The codec exposes exactly these repository-SPI operations:

- encode `WireHello`, `WireErrorPayload`, or `WireDisconnect`;
- decode one `WireFrame` under `.preHandshake` into a sealed Sendable `WirePreHandshakeMessage` whose cases contain `WireHello`, `WireErrorPayload`, or `WireDisconnect`.

There is no generic public encode, raw `WireMessage` accessor, `WireAdmittedMessage` input or output, payload protocol exposure, arbitrary type token, or caller-supplied phase/capability set. A value admitted by another codec cannot enter this API.

### 3. Reuse one validation pipeline

Encode first applies `WireMessageAdmission` for control lane, `.preHandshake`, and an empty capability set, then delegates to the existing deterministic message and frame codec with V1 and immutable limits.

Decode first applies lane preflight so an Event frame is rejected before JSON parsing, regardless of whether its bytes or claimed envelope version would otherwise be malformed. For a Control frame, bounded deterministic envelope decoding parses and validates the nonzero version first. A module-internal optional expected-version guard in the raw decoder then rejects a non-V1 version with `incompatibleVersion` before parsing or interpreting the type, required lane, or body under V1 semantics. Version zero therefore retains the version model's `invalidConfiguration` code, while nonzero non-V1 versions have deterministic incompatibility precedence even if later fields conflict with V1 rules. The pre-handshake codec always supplies V1 to that guard and exposes no caller-selectable expected version.

After a V1 Control envelope is established, the codec applies exact pre-handshake message admission, switches over the three admitted types, decodes the corresponding payload model under the same limits, and only then constructs the sealed typed enum. Every decode failure is normalized to a connection-terminal `WireProtocolError`, matching negotiated-session decode behavior.

The switch has no default success path. A malformed hello, safe error, or disconnect body cannot become a returned pre-handshake value. Because the result is already typed and sealed, there is no second typed-decode operation and no cross-codec admitted token to reinterpret.

### 4. Keep limits conservative and immutable

The initializer accepts only an already validated `WireProtocolLimits` value and stores it immutably. It cannot widen frame, control-text, collection, JSON, or event-model limits. Pre-handshake messages remain on the control lane and are bounded by the control-frame limit.

The codec retains only limits. A returned enum owns its decoded bounded payload, but the codec stores no frame, payload, hello, identity, pairing code, endpoint, continuation, closure, task, or application content between calls.

### 5. Keep the application boundary unchanged

The codec and sealed pre-handshake enum remain `NearWireInternal` SPI for repository-owned modules. A normal `import NearWire` consumer cannot name either type, and CocoaPods same-module compilation must not make them supported application API. Package products, targets, and dependency inventories remain unchanged.

## Operation Table

| Operation | Input | Result |
| --- | --- | --- |
| encode | valid hello/error/disconnect | Deterministic V1 control frame. |
| encode | any other message path | No supported overload exists. |
| decode | valid V1 hello/error/disconnect control frame | Sealed typed pre-handshake enum after payload-model validation. |
| decode | Event lane | Terminal phase/lane error before JSON parsing. |
| decode | Control lane with zero envelope version | Terminal invalid-configuration error from version validation. |
| decode | Control lane with nonzero non-V1 envelope version | Terminal incompatible-version error before type, required-lane, or body interpretation. |
| decode | hello acknowledgement, connection rejection, ping, or pong | Terminal phase-violation error. |
| decode | flow-policy offer or acceptance | Terminal unsupported-message-type error because no capability exists before negotiation. |
| decode | event, event batch, or drop summary, including malformed JSON | Terminal phase-violation error at Event-lane preflight. |
| decode | syntactically valid unknown Control type | Terminal unsupported-message-type error. |
| decode | malformed body for an allowed type | Terminal payload-model error; no enum value is returned. |

## Test Strategy

- Golden round trips prove exact deterministic hello, safe-error, and disconnect bytes.
- A hello with a wider advertised version interval still uses the fixed V1 bootstrap envelope and can feed `WireNegotiator` after the remote hello arrives.
- Event-lane preflight uses deliberately invalid JSON to prove rejection happens before payload parsing.
- Canonical raw zero-version and future-version Control frames prove their distinct exact terminal codes; mixed-invalid future envelopes prove version rejection precedes V1 type, lane, and body interpretation.
- Hello acknowledgement, connection rejection, both flow-policy messages, ping, pong, event, event batch, drop summary, and unknown type are each tested with their exact terminal code.
- Canonical envelopes with malformed or over-limit hello, safe-error, and disconnect bodies fail in `decode(frame:)` before a sealed enum exists.
- Malformed JSON, noncanonical JSON, duplicate and escaped-equivalent keys, and oversized control payloads fail terminally at the new SPI boundary.
- Limit tests prove custom tighter control and model bounds are honored without widening.
- Compile-time Sendable and retention tests prove the codec and sealed result are concurrency-safe while the codec remains immutable and content-free.
- SPI and application API inventories prove raw messages, payload protocols, admitted-message internals, the sealed pre-handshake enum, and the codec remain unavailable to normal consumers.
