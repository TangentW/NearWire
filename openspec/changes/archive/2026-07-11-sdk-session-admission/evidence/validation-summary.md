# Session Admission Validation Summary

## Canonical Run

- Run ID: `20260711T144338Z-25288`
- Started: `2026-07-11T14:43:38Z`
- Finished: `2026-07-11T14:46:16Z`
- Command: `./Scripts/capture-bootstrap-evidence.sh openspec/changes/sdk-session-admission/evidence/raw all`
- Capture status: complete and internally consistent
- Environment: Xcode 26.6 (build 17F113), Apple Swift 6.3.3 compiling distributed source in Swift 5 mode, CocoaPods 1.16.2, OpenSpec 1.2.0

## Exact Results

| Gate | Result |
| --- | --- |
| Strict OpenSpec | 22 passed, 0 failed |
| Repository structure | Passed |
| English source and documentation scan | Passed; semantic review completed by the security/documentation reviewer |
| Validation-tool self-tests | Passed |
| Version contract | Passed for 0.1.0 |
| Module and distribution boundaries | Passed |
| iOS Simulator package suite | 288 total: 287 passed, 1 expected macOS-only TLS skip, 0 failed |
| macOS Core harness | 178 passed, 0 failed |
| Dedicated real-TLS admission gate | Exactly 1 selected, 1 passed, 0 skipped, 0 failed |
| CocoaPods lint | Passed |

The CocoaPods log contains the existing expected placeholder-URL warning for `https://example.invalid/nearwire`; validation still completed successfully. App Intents metadata notes are expected because the SDK does not depend on AppIntents.

## Focused Admission Run

- Command: `swift test --filter SDKSessionAdmissionTests`
- Finished: `2026-07-11T22:47:39+08:00`
- Platform: `arm64e-apple-macos14.0`
- Result: 29 tests executed, 29 passed, 0 skipped, 0 failed in 0.041 seconds
- The production-channel TLS test executed and passed in 0.011 seconds.

## Raw Evidence

The exact command lines, run identity, timestamps, stdout, stderr, and exit status for every canonical gate are retained in `evidence/raw`. `all-capture-status.log` records `STATUS: complete` and exit status 0.
