# Implementation Review Round 4: Correctness and Testing

Date: 2026-07-14

## Verdict

Changes requested. Four actionable findings remained.

## Findings

### P1: Prepared operation authority can survive Store replacement

Prepared delete/export tickets and destination selection could outlive their originating Store.
Blanket cancellation could also remove an already Store-committed export execution slot and suppress
its authoritative completion.

### P1: Catalog-page bounds are mistaken for identity absence

The first 50/100 rows could not prove whether selected recording/device logical identities survived
elsewhere in the replacement catalog.

### P1: Snapshot failure is not terminal

The rematerialization receipt could complete while recording state remained `loading`.

### P2: Replacement race coverage is incomplete

Tests did not cover a surviving recording with a reused/missing device identity, snapshot failure,
stale prepared operations, or Store-committed export completion during rematerialization.

## Other observations

Committed export completion must retain the active execution slot, request cancellation, and let the
existing authoritative-delivery path publish its result. No files were modified by the reviewer.
