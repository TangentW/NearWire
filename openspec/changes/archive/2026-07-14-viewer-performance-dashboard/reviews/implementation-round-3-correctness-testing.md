# Implementation Review Round 3: Correctness and Testing

Date: 2026-07-14

## Verdict

Changes requested. One P1 finding remained.

## Finding

### P1: Store replacement can scan reused row IDs before replacement catalogs are installed

The application started Explorer's asynchronous Store refresh and immediately told the analysis
coordinator that the Store had been replaced. The coordinator joined transition, Performance, and raw
resolver cleanup, but not the change-snapshot to recording/device-catalog chain. It could therefore
recompile from predecessor rows and query a replacement Store whose reused numeric recording/device
row IDs represented different logical identities. Later catalog callbacks could also admit a second
successor, violating the exactly-one-successor requirement.

The reviewer requested an Explorer Store-rematerialization barrier that clears target authority
immediately and rebuilds only after replacement recording/device catalogs commit, plus a real blocked
catalog integration test with reused row IDs.

## Validation reported by reviewer

- Five focused tests passed.
- Strict OpenSpec validation passed.
- `git diff --check` passed.
- Configured signing was intentionally excluded.

The retired-deadline and cache-generation changes were otherwise considered correct.
