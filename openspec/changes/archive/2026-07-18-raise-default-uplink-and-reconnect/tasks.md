## 1. Specification

- [x] 1.1 Define exact recovery, rate, burst, queue, migration, and presentation-ingress behavior.
- [x] 1.2 Validate proposal, design, capability deltas, and tasks in strict mode.

## 2. SDK defaults and session control

- [x] 2.1 Add the automatic recovery preset and make it the SDK default while preserving opt-out.
- [x] 2.2 Raise default SDK uplink and offline queue bounds.
- [x] 2.3 Apply the 0.25-second burst profile to SDK business-Event buckets.

## 3. Viewer defaults and bounds

- [x] 3.1 Raise the Viewer default uplink request and migrate only the legacy global default.
- [x] 3.2 Split per-device uplink/downlink queue bounds and expand only uplink.
- [x] 3.3 Apply the business burst profile and expand presentation ingress to 2,048 Events.

## 4. Coverage and validation

- [x] 4.1 Add focused SDK, flow-control integration, Viewer preference, queue, and ingress tests.
- [x] 4.2 Run focused and complete maintained tests/builds plus formatting and strict OpenSpec
      validation.
- [x] 4.3 Save exact command results under this change's evidence directory.

## 5. Review and archive

- [x] 5.1 Run independent architecture/API, correctness/testing, and
      security/performance/documentation reviews.
- [x] 5.2 Resolve every actionable finding and run a fresh no-findings review round.
- [x] 5.3 Complete a spec-to-evidence audit and archive the change.
