## Why

The production SDK advertises the maximum deterministic Event-record size in its App Hello. That
offer is slightly larger than the default 256 KiB Event-content limit because it includes the wire
record envelope. Viewer currently decodes peer Hello offers with its own local 256 KiB session
limit, rejects the SDK's valid offer before conservative negotiation, and closes an otherwise
successful Bonjour, TCP, and TLS connection.

## What Changes

- Treat `maximumEventBytes` in a pre-handshake Hello as a bounded peer offer rather than an already
  selected local session limit.
- Validate that offer against the existing 16 MiB protocol hard bound while preserving the control
  frame, collection, text, and model limits used to decode the Hello itself.
- Keep session construction conservative: the negotiated value remains the smaller advertised
  offer and `WireSessionCodec` must still reject any result above its local active limit.
- Add Core and Viewer regressions using the same exact Event-record maximum advertised by the
  production SDK.

## Capabilities

### Modified Capabilities

- `wire-session-negotiation`: Separates bounded pre-handshake offer validation from the local
  post-negotiation Event limit.
- `viewer-application-foundation`: Requires Viewer admission to accept the production SDK's valid
  larger offer and negotiate it down to Viewer's local supported value.

## Impact

- Changes one repository-internal Core wire validation rule and affected tests.
- Adds no public API, dependency, transport, allocation, persistence, or wire-schema change.
- Event payloads remain dynamically sized. The current 256 KiB content maximum is not increased or
  made configurable by this change.
