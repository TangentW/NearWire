## 1. Planning Gate

- [x] 1.1 Inspect the existing SDK lifecycle, Demo scene integration, Viewer replacement behavior, tests, and prior evidence.
- [x] 1.2 Complete proposal, design, capability delta, and this task plan.
- [x] 1.3 Strictly validate the active OpenSpec change before source modification.

## 2. Demo Lifecycle Integration

- [x] 2.1 Configure the Demo's sole NearWire instance with the fixed bounded recovery policy.
- [x] 2.2 Forward background and active scene phases through the model/driver to the supported suspend/resume API while ignoring inactive.
- [x] 2.3 Update the Demo runbook with exact background and recovery limits.
- [x] 2.4 Migrate an active selected Viewer Device to an exact logical-route replacement before the next Timeline evaluation.

## 3. Focused Regression Coverage

- [x] 3.1 Add one compact Demo recovery-configuration and lifecycle-forwarding regression without emulating transport.
- [x] 3.2 Add an SDK regression proving an Event queued while suspended drains on the fresh resumed route.
- [x] 3.3 Add a Viewer regression proving exact-route replacement migrates active selection and exposes a fresh-epoch Event through the live Timeline path.

## 4. Validation and Evidence

- [x] 4.1 Run the focused regressions, affected suites, SwiftPM/CocoaPods consumer validation, and iOS Simulator build/launch smoke; record exact results.
- [x] 4.2 Run a real-iPhone background/foreground smoke if device access and existing user-owned signing configuration permit it; otherwise record the exact limitation.
- [x] 4.3 Run `git diff --check`, strict-concurrency/build checks, and strict OpenSpec validation.

## 5. Review and Completion

- [x] 5.1 Run independent architecture/API, correctness/testing, and security/performance/documentation reviews.
- [x] 5.2 Fix every actionable finding and run a fresh clean review round.
- [x] 5.3 Complete the spec-to-evidence audit and archive the change.
