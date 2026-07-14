# Implementation Review Round 2: Architecture and API

Date: 2026-07-14

## Verdict

Changes requested with two unresolved actionable findings.

## Findings

1. **P1: Store replacement could lose or prematurely rebuild a Performance target.** Store
   replacement invalidated an in-flight analysis transition, but its successor path reactivated only
   Events. Replacement during Performance entry, a range transition, or raw reveal could therefore
   leave no rebuilt Performance target. In stable-target cases, the controller could instead start
   its successor before the coordinator joined the prior transition and raw resolver. The reviewer
   required the coordinator to own invalidation-without-rebuild, all predecessor joins, selection
   recompilation, and exactly one successor admission, with blocked transition/range/reveal tests.
2. **P2: An exact historical cache hit could retain representative authority from an older source
   generation.** The cache key intentionally excludes source generation, while range replacement
   advances it. A historical A-to-B-to-A range round trip could therefore publish A's old cached
   representatives and make Open Source Event unavailable. The reviewer required generation-
   validated cache reuse or bounded replacement/rebinding plus an A-to-B-to-A raw-reveal test.

The reviewer confirmed closure of live-only fallback clearing and the direct ready, paused,
blocked-scan, and claimed-delivery Store cleanup paths. No repository files were edited by the
reviewer.
