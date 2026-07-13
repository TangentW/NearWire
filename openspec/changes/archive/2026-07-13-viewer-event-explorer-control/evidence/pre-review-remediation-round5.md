# Pre-Implementation Review Remediation — Round 5

## Status

The round-4 architecture source-seam check identified that “complete canonical Event envelope” was
not durably representable: the Events table intentionally omits source, target, and session epoch and
stores App-created wall time at millisecond precision. The artifacts were corrected without adding
columns, duplicating Event content, or broadening schema-2 migration.

Because this correction occurred after the round-4 correctness and round-5 SPD approvals were being
finalized, a fresh common-snapshot review is required in all three dimensions.

No production or test source was modified.

## Durable duplicate projection

Live ingress and the writer now compare the same representable semantic projection:

- the exact journal key provides runtime/connection/direction/sequence;
- compared values are Event ID/type, canonical content JSON bytes, App-created wall time normalized
  once to nearest integer milliseconds since 1970, App monotonic time, priority, TTL, schema version,
  correlation/reply IDs, and initial disposition;
- source, target, and session epoch are excluded because the transport/session boundary validates
  them against the exact session before journal commit;
- frozen session metadata, deterministic byte accounting, and newly sampled Viewer receive times
  are excluded and the first values remain authoritative; and
- fields/bytes are compared directly rather than trusting a hash.

This matches the existing immutable Events representation and requires no new privacy-sensitive
Viewer identity/epoch storage. Task 6.3 now proves metadata/accounting/receive-only differences and
sub-millisecond times normalizing to the same millisecond remain equal, while any stored-projection,
initial-disposition, or normalized-millisecond difference conflicts. It also proves endpoint/epoch
mismatch is rejected before journal commit across every duplicate-authority state.

## Validation

- Strict OpenSpec validation: exit 0.
- `git diff --check`: exit 0.
- No production or test source changed.

Implementation remains blocked pending fresh common-snapshot approval.
