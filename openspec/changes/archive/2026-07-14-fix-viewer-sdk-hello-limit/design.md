## Context

`WireHello.maximumEventBytes` is an offer. The peers must decode both offers before
`WireNegotiator` can select the smaller value. Today `WireHello` validates the peer's offer against
the decoding codec's `WireProtocolLimits.maximumEventBytes`, which is also used as the local active
session limit. Viewer therefore applies its local 256 KiB limit too early and rejects the SDK's
slightly larger exact Event-record offer.

The offer is only a bounded integer inside a small Control frame. Decoding it does not allocate an
Event-sized buffer. Actual Event frame, channel, queue, and storage capacities are selected and
validated after negotiation.

## Goals / Non-Goals

**Goals:**

- Decode a valid peer Event-size offer before applying the local active-session limit.
- Preserve the existing smaller-offer negotiation and local session-codec cap.
- Cover the exact SDK-to-Viewer value that failed at runtime.

**Non-Goals:**

- No increase to the current 256 KiB Event-content maximum.
- No new public configuration for large Events, fragmentation, attachments, or streaming.
- No change to Bonjour, TLS, pairing, queues, rate limits, or Viewer persistence.

## Decisions

### 1. Hello offers use the existing wire hard bound

`WireHello` will validate a positive `maximumEventBytes` offer against
`WireFrameLimits.hardMaximumPayloadBytes` rather than the caller's local active Event limit. The
other supplied protocol limits continue to validate codecs, collections, text, metadata, and the
encoded Control frame.

This keeps one symmetric rule for App and Viewer and avoids a Viewer-only exception. A dedicated
larger bootstrap codec is unnecessary because the Hello remains a small bounded Control frame and
only its scalar offer needs different semantics.

### 2. Negotiated session limits remain local and conservative

`WireNegotiator` continues selecting the smaller advertised offer. `WireSessionCodec` continues
requiring that selected value to fit its supplied local `WireProtocolLimits.maximumEventBytes` and
frame limits. A peer cannot widen memory, queue, transport, or storage capacity by advertising a
large number.

### 3. Tests cross the previous boundary without expanding payloads

Core coverage will round-trip a Hello whose offer is above the decoder's local 256 KiB session
limit, verify conservative negotiation, and verify that the resulting session codec still cannot
exceed its local limit. Viewer coverage will feed admission a Hello advertising
`WireEventRecord.maximumDeterministicEncodedByteCount`, matching the production SDK calculation,
and require successful handoff instead of cancellation.

No test allocates a maximum-sized Event body.

## Risks / Trade-offs

- **A malicious peer advertises 16 MiB.** The value is only parsed as an integer; no capacity is
  allocated from it, and negotiation/session construction still applies the local cap.
- **Callers previously used `WireHello` construction to enforce a local offer.** Internal callers
  already derive their own offer from reviewed limit plans. Session construction remains the
  authoritative local-cap gate.
- **Large-JSON expectations become ambiguous.** Documentation in this change explicitly preserves
  dynamic Event sizing and the current 256 KiB content maximum; configurable larger Events remain a
  separate design.

## Migration Plan

No data or API migration is required. Rollback restores the previous Hello validation and the
SDK-to-Viewer connection failure.

## Open Questions

None for this fix.
