# Implementation Review Round 3: Security, Performance, and Documentation

Date: 2026-07-14

## Verdict

Changes requested. Two P1 findings remained.

## Findings

### P1: Retired deadline work is unbounded

The implementation retained one handle per replaced deadline and drained handles serially. Its
cooperative test demonstrated 1,800 physical jobs and as many retained handles, contradicting the
bounded-state and one-physical-wake contract. A handle that never completed could also retain the
drain owner indefinitely.

The reviewer requested one reschedulable physical worker, or another numerically bounded design that
still joins physical completion, with a 1,800-arm assertion for bounded physical and retained work.

### P1: Store replacement does not join Explorer rematerialization

The coordinator did not join the asynchronous recording/device-catalog rebuild that followed a Store
replacement. It could compile from stale rows before catalogs completed, and a later selection
callback could admit an additional successor.

The reviewer requested an Event-side Store-rematerialization receipt in the replacement barrier and
an integrated blocked snapshot/catalog test. Static target-selection closures were not sufficient
coverage.

## Other observations

The representative-cache replacement preserved reservation ownership and active source-generation
authority. No additional privacy sink was found.
