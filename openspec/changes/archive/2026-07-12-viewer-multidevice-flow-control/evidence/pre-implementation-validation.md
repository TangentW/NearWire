# Pre-implementation Validation

Date: 2026-07-13

No production or test source was modified before the proposal, design, capability specification, and task plan were complete.

## OpenSpec artifact status

Command:

```text
DO_NOT_TRACK=1 openspec status --change viewer-multidevice-flow-control
```

Result: exit 0. OpenSpec reported `4/4 artifacts complete` for proposal, design, specs, and tasks.

## Strict OpenSpec validation

Command:

```text
DO_NOT_TRACK=1 openspec validate viewer-multidevice-flow-control --strict
```

Result: exit 0. OpenSpec reported `Change 'viewer-multidevice-flow-control' is valid`.

## Diff hygiene

Command:

```text
git diff --check
```

Result: exit 0 with no output.

## English-language gate

Command:

```text
rg -n "[\p{Han}]" openspec/changes/viewer-multidevice-flow-control
```

Result: exit 1 with no matches, which is the expected successful result for this negative search.

## Post-review artifact remediation

The first independent artifact review round reported three architecture/API findings, three correctness/testing findings, and four security/performance/documentation findings. The artifacts were revised before any production or test source work to define:

- conservative V1 policy acceptance with one in-flight transaction and exact monotonic deadline winners;
- synchronous reentrant same-core attachment, provisional rollback, and lock ordering;
- unauthenticated correlation hints, rejection of live duplicate claims, and connection-bound downlink ownership;
- a 64-row recent-disconnect limit, deterministic eviction, one manager expiry wake, and total lifecycle transitions;
- atomic inbound and downlink sequence commit points;
- finite ingress byte/frame/record/system-message/service quanta and sender-contract enforcement; and
- closed diagnostics plus a built privacy-manifest rationale and inspection gate.

The strict OpenSpec, artifact status, diff hygiene, and English-language commands above were rerun unchanged after remediation on 2026-07-13. Results remained: strict validation exit 0, `4/4 artifacts complete`, diff check exit 0, and the negative Han-character search exit 1 with no matches.

## Round 2 remediation

Round 2 found two architecture/API contradictions, one correctness presentation-state issue, and one security/performance callback-coalescing issue. Before source work, the artifacts were revised again to:

- define the observable V1 rule for an indistinguishable lower acceptance while a later offer is pending;
- reject only an exact live correlation tuple while treating a same-installation different/missing Bundle ID as a separate non-inheriting row;
- remove the undefined `reconnecting` state in favor of ordinary negotiating state; and
- separate hard ingress/token bounds from service-turn quanta through a bounded pause/resume Core decoder seam, one ordered same-core continuation, and split-versus-coalesced equivalence.

Strict OpenSpec validation, `git diff --check`, and the English-language negative search were rerun unchanged on 2026-07-13. Results were exit 0, exit 0, and expected exit 1 with no matches, respectively.

## Round 6 remediation

Round 6 found only an evidence wording omission: negotiating owners were normative but absent from the mixed 16-slot test sentence. Proposal, design goal, and tasks now consistently require the same four owner states—provisional, negotiating, active, and disconnecting—through cleanup, including a barrier-controlled mixed registry and 17th rejection.

## Round 5 remediation

Round 5 reduced the remaining issue to one composed state: `deadlineElapsed` plus decoder `needsMoreBytes`. The generic decoder rule is now explicitly limited to the ordinary no-timeout path. When recorded timeout classification reaches drained or partial-only input without acceptance, timeout closes, clears decoder/token state, and never resumes receive; deterministic coverage is required for both the ordinary partial-resume and timeout partial-no-resume branches.

Strict OpenSpec validation, `git diff --check`, and the English-language negative search were rerun unchanged on 2026-07-13. Results were exit 0, exit 0, and expected exit 1 with no matches, respectively.

## Round 4 remediation

Round 4 verified the receive-pause ownership and 2/19 MiB arithmetic, then identified two final state transitions. Policy timeout now records elapsed state and defers terminal commit while an already-owned pre-deadline suffix is classified, so continuation scheduling cannot invalidate a timely acceptance. Decoder progress now distinguishes a complete paused frame from a partial tail: a partial tail remains charged but detaches the old token/continuation before one receive resumes, with explicit immediate-callback and terminal winner rules.

Strict OpenSpec validation, `git diff --check`, and the English-language negative search were rerun unchanged on 2026-07-13. Results were exit 0, exit 0, and expected exit 1 with no matches, respectively.

## Round 3 remediation

Round 3 identified receive-time ambiguity and the inability of a decoder-only pause to stop `SecureByteChannel` from eagerly rearming its driver. The artifacts now define one frame-completion receipt sample for every receive-time decision and authorize a narrow generation-bound Core receive-pause token. The token is synchronously claimed during delivery, prevents rearm, is retained with one decoder suffix/continuation, resumes once after drain, and invalidates without rearm on terminal cleanup. Total input accounting includes decoder bytes plus transient callback `Data`, with a 2 MiB default and 19 MiB hard maximum.

Strict OpenSpec validation, `git diff --check`, and the English-language negative search were rerun unchanged on 2026-07-13. Results were exit 0, exit 0, and expected exit 1 with no matches, respectively.
