# Archive verification

The change archived successfully and updated the canonical
`viewer-event-explorer-control` specification.

The archive tool initially replaced each modified requirement with only the scenarios present in
the delta, which removed unchanged pre-existing scenarios from the canonical specification. The
unchanged scenarios were restored in both the canonical specification and archived delta:

- more than 512 retained matching Events;
- normal admission disposition;
- selected Event eviction;
- normal-cadence refresh;
- immediate Inspector tab changes.

Post-correction checks:

- all seven pre-existing and two new scenarios are present in both specification copies;
- the followed-append scenario preserves its prior receive-order, stable-identity, and
  no-container-replacement guarantees while adding the real-row/no-transient-tail guarantees;
- `openspec validate --all --strict` passed 33 specifications with 0 failures;
- `git diff --check` passed;
- the canonical diff now contains only the intended tail-target wording and new 70/30 panel
  behavior.
