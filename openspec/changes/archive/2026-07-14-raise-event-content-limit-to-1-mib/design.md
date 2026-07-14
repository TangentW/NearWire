# Design: Fixed 1 MiB Event Content

## Context

NearWire has several byte domains with different meanings:

1. canonical ordinary JSON content bytes;
2. the internal tagged Codable Event draft used for bounded offline memory accounting;
3. the ordinary-JSON wire Event record containing metadata and content;
4. the wire message and frame containing that record;
5. secure-channel pending-send and receive retention.

The product limit in this change applies to the first domain. Treating every domain as exactly
1 MiB would reject a valid boundary Event after metadata or framing is added.

## Goals / Non-Goals

**Goals:**

- Accept canonical Event content whose deterministic JSON encoding is at most 1,048,576 bytes.
- Reject content at 1,048,577 bytes before queue or transport mutation.
- Carry a boundary Event through SDK queueing, deterministic record encoding, Viewer negotiation,
  frame decoding, and Viewer session admission.
- Keep all intermediate capacities finite, derived, and covered by boundary tests.

**Non-Goals:**

- No configurable content capacity in this release.
- No promise that arbitrary binary data should be embedded in JSON efficiently.
- No eager allocation at any advertised maximum.

## Decisions

### 1. One fixed content constant

The default `EventValidationLimits.maximumEncodedContentBytes` becomes 1 MiB. Existing structure,
depth, collection, string, key, and numeric validation remains unchanged. A value below the limit
uses only its actual encoded bytes.

### 2. Internal model accounting remains conservative

The internal tagged Codable representation may expand ordinary JSON. Its default bound becomes the
existing proven formula:

`4 * 1,048,576 + 65,536 = 4,259,840 bytes`.

The default single-Event queue accounting bound uses that derived value, while the default total
queue byte budget becomes 16 MiB. The count limit remains 1,000, so queue overflow still evicts
according to existing policy and no queue can retain 1,000 maximum-size Events.

The active SDK pump's default outbound-accounting quantum also becomes 4,259,840 bytes so the
default queue can service one valid maximum-accounted Event without requiring a special connection
plan or failing active-session admission.

`NearWireBufferConfiguration.maximumEventBytes` continues to mean the encoded in-memory Event
accounting bound, not the canonical content limit. The fixed canonical content limit is not exposed
as a new configurable API.

When a caller explicitly supplies a smaller total buffer but omits `maximumEventBytes`, the
effective single-Event accounting limit is the smaller of 4,259,840 bytes and that total. This
preserves the existing source call pattern while an explicitly supplied incoherent single-Event
limit remains an error.

### 3. Wire capacity includes exact record and frame overhead

`WireEventRecord.maximumDeterministicEncodedByteCount` remains the authority for the maximum
ordinary-JSON record size. It adds the fixed maximum metadata wrapper to the 1 MiB content bound
without allocating a maximum-size body.

The default Event lane payload capacity becomes 2 MiB so the exact record plus the small V1 message
wrapper fits. Control remains 64 KiB and the hard payload ceiling remains 16 MiB. Default protocol
and Hello offers use the exact deterministic record bound, not the 1 MiB content number.

### 4. App and Viewer use the same production capacity

The SDK connection plan continues deriving its wire and secure-channel capacities from the exact
record calculation. Viewer admission, frame decoding, and active session codec use the updated
shared production defaults, so neither side negotiates below the supported record size by accident.

Negotiation still selects the smaller peer offer. A deliberately smaller peer therefore remains a
valid conservative cap and cannot be widened by this default change.

### 5. Boundary coverage uses real content

Tests construct valid ordinary JSON at exactly 1 MiB using bounded strings and arrays, plus a value
one byte over the limit. Coverage proves exact acceptance/rejection, SDK offline queue admission,
record/frame traversal, Viewer handoff, and unchanged hard-bound rejection. Tests do not reserve or
fill unrelated queue capacity.

## Risks / Trade-offs

- **Higher peak memory per Event.** The queue and transport remain bounded, account actual bytes,
  and retain existing overflow behavior. Default total queue bytes rise only enough for several
  worst-case Events, not 1,000 of them.
- **More work to validate large JSON.** Existing depth, entry, and per-string caps remain, and frame
  preflight rejects oversized input before full payload retention.
- **Peers with older defaults negotiate smaller capacity.** This is expected protocol behavior;
  the sender receives the existing local encoding/queue outcome rather than silent truncation.
- **Exact 1 MiB content does not equal a 1 MiB frame.** Documentation names each byte domain and
  tests protect the required overhead calculations.

## Migration Plan

No data migration is required. Applications using default configuration gain the larger capacity.
Applications with explicit smaller buffer or peer limits keep those conservative limits. Rollback
restores the prior defaults and rejects content above 256 KiB.

## Open Questions

None for the fixed-capacity release. Runtime configurability and large-payload transport belong to a
future, separately reviewed change.
