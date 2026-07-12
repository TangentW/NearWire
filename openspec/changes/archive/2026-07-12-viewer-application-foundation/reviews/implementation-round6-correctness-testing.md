# Implementation Correctness and Testing Review — Round 6

Date: 2026-07-12

## Scope

Independently re-read the current `viewer-application-foundation` artifacts, Viewer production and test source, manual project and shared scheme, signed-host resources, operator documentation, implementation evidence, requirement-to-evidence audit, all Round 5 implementation reports, and the current remediation state. This review specifically audited the build-setting-to-signed-Info.plist configuration path, ordinary skip behavior, fail-closed phase parsing, create/deny/verify ordering, signed host build and signer identity checks, and the documented fail-fast command sequence. It also rechecked the previously approved cleanup-receipt and capacity-recycling behavior proportionately. No production, specification, task, test, documentation, or evidence artifact was modified; this report is the only added file.

## Round 5 Finding Disposition

| Round 5 correctness/testing finding | Round 6 disposition |
| --- | --- |
| Shell-prefixed probe variables did not reach app-hosted XCTest, and verify did not prove deny completed | **Resolved.** The four explicit probe build settings now expand into reserved fields in the signed host Info.plist, and the XCTest reads only that signed configuration. A fresh invalid-phase build proved the setting reached the host and failed the test rather than skipping. Verify requires the token-scoped `deny-complete` marker, while the documented `set -e` sequence creates that marker only after the deny test exits successfully. |

## Fresh Correctness Audit

No unresolved correctness or testing finding was identified.

### Signed configuration reaches the app-hosted test

`Viewer/NearWireViewer/Resources/Info.plist` binds phase, token, build ID, and state root to `NEARWIRE_SIGNER_PROBE_*` user build settings. `testStableSignerUpdateBoundaryProbe` reads the resulting values from `Bundle.main.infoDictionary`, so the configuration is part of the signed app host rather than an unforwarded `xcodebuild` environment (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:523-542`).

A fresh safe command set `NEARWIRE_SIGNER_PROBE_PHASE=invalid` as an Xcode user build setting. The built host Info.plist contained `NearWireSignerProbePhase = invalid`, and the selected XCTest failed with exit 65 at phase decoding rather than reporting a skip. This closes the Round 5 false-success path.

When the reserved phase field is empty, the same test intentionally skips before any state, Security, or Keychain operation. The fresh ordinary suite retained exactly one skip and no other conditional omission.

### Phase order is fail closed

Create alone makes the token-scoped directory and refuses an existing create record. Deny requires a distinct signed product and signer before it exercises the production store and exact-selector denial operations. Verify requires both the create record and `deny-complete`; a create-to-verify sequence without that marker throws `invalidProbeConfiguration` before identity load or reset (`ViewerFoundationTests.swift:556-611`).

The documented commands run under `set -e`. The shell touches `deny-complete` only after the deny `xcodebuild test` exits successfully, so an assertion failure, signing failure, malformed phase, skip-to-failure guard, or test-process failure prevents the marker and stops the sequence. Verify removes the token directory only after authorized identity verification and both supported reset scopes complete.

### Distinct signed products and signers are mechanically checked

The create record binds the stable product to all of the following:

- the signed host's `CFBundleVersion`;
- the host Code Directory hash from `SecCodeCopySelf` signing information;
- `Bundle.main.bundleURL.path`, which is the signed Viewer application path rather than the XCTest bundle path;
- the operator build identifier carried in the signed host Info.plist; and
- the runtime Team ID, leaf signing-certificate hash, and designated requirement.

Deny requires different build ID, signed host path, bundle version, Code Directory hash, composite signer fingerprint, and specifically a different designated requirement. Verify requires different build identity fields while matching the complete original stable signer fingerprint (`ViewerFoundationTests.swift:549-611,648-700`). The documented A/unrelated/B commands use separate DerivedData paths and bundle versions `1001`, `2001`, and `1002`, so correctly executed products satisfy the intended distinctions without trusting only operator labels.

The denial operation coverage remains proportionate: production load, TLS reset, full reset, exact generic-password reads, exact private-key lookup and signing use, and exact generic-password/key/certificate deletion are attempted noninteractively. The final stable product verifies the original installation ID, certificate hash, and real private-key signing before authorized resets.

### Cleanup and capacity behavior remains closed

The Round 5 cleanup ordering remains unchanged and coherent. Attempt completion releases the exact reservation before registry completion, accepted handles await both core and cleanup-owner completion, and the stop receipt joins registry plus handoff-owner shutdown. The same-runtime test still establishes 32 occupied slots, exact release to 24, refill to 32, overflow rejection before claim, and final exact-once drain.

## Independent Validation

- Fresh ordinary Viewer app-hosted XCTest: **PASS**. The result contained 56 tests: 55 passed, the stable-signer gate was the sole skip, 0 failed, and 0 expected failures.
- Current source after the `Bundle.main.bundleURL.path` tightening compiled and the focused ordinary signer test retained its intentional skip.
- Safe invalid-phase gate: expected exit 65 with one failed signer-probe test and no skip. The built signed-host Info.plist contained `NearWireSignerProbePhase = invalid`; other unset probe fields remained empty.
- Previously completed focused cleanup-receipt and same-runtime recycling repetition remained 40 passed runs with no failure or skip; no affected cleanup source changed in this remediation.
- `security find-identity -v -p codesigning`: `0 valid identities found`. No external cross-signer behavior is claimed as executed.
- Strict OpenSpec validation and `git diff --check`: **PASS**.

## External Completion Gate

The implementation and reproducible command design are approved, but the change must remain active until the documented A/unrelated/B sequence is executed on a host with two valid unrelated signing identities and its exact results are saved. The current absence of identities is an external evidence dependency, not an unresolved implementation finding, and the audit correctly leaves that requirement pending.

## Verdict

**Approved. Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, and 0 Low.**
