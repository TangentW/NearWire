# Implementation Correctness and Testing Review — Round 5

Date: 2026-07-12

## Scope

Independently re-read the current `viewer-application-foundation` proposal, design, capability specifications, tasks, current production and test source, the manual Viewer project and shared scheme, resources, operator documentation, implementation evidence, requirement-to-evidence audit, all three Round 4 implementation reports, and `evidence/implementation-round4-remediation.md`. This review retraced deterministic cleanup-receipt ordering, exact-once slot release, same-runtime capacity recycling, claim cleanup, and every create/deny/verify branch and documented command of the conditional stable-signer gate. No production, specification, task, test, documentation, or evidence artifact was modified; this report is the only added file.

## Round 4 Finding Disposition

| Round 4 correctness/testing finding | Round 5 disposition |
| --- | --- |
| Stable-signer evidence was unexecuted and the unrelated-signer branch did not cover reset/deletion denial | **Operation coverage materially improved, gate still not valid.** The deny branch now uses a different designated requirement and independently exercises store load, TLS reset, full reset, exact generic-password reads, exact private-key lookup/signing use, and exact generic-password/key/certificate deletions. The final stable branch verifies the original identity before authorized resets. However, the documented shell-prefixed environment variables do not reach the app-hosted XCTest, so all three commands silently skip the probe and return success. The phase state also permits create-to-verify without a completed deny phase; see Finding 1. |
| Handoff receipt completion was not ordered after reservation release and no same-runtime 32→24→32 proof existed | **Resolved.** The accepted handle retains its attempt cleanup owner, `cancelAndWait()` joins both core cleanup and the release completion, and the cleanup registry retains handed-off attempts. `onComplete` releases the reservation before removing the registry owner, and completion waiters are resumed afterward. The new same-manager test closes eight of 32 accepted handles, deterministically observes 24, refills eight to 32, rejects overflow before claim, and drains every channel exactly once. |

## Finding

### 1. P2 / Medium — The documented stable-signer gate silently skips every phase and does not require the deny phase before verification

**Confidence: 10/10**

The conditional XCTest reads `NEARWIRE_SIGNER_PROBE_PHASE`, `TOKEN`, `BUILD_ID`, and `STATE_ROOT` from the test process environment and intentionally skips when `PHASE` is absent (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:523-536`). The operator documentation supplies those values only as shell environment assignments before `xcodebuild` (`Documentation/Viewer-Foundation.md:15-29`). The shared scheme defines no test-action environment variables or build-setting expansion for these keys (`Viewer/NearWireViewer.xcodeproj/xcshareddata/xcschemes/NearWireViewer.xcscheme`).

A fresh command-equivalent execution used the current documented shell-prefixed values, including the constrained container `STATE_ROOT`, and selected only `testStableSignerUpdateBoundaryProbe` against the current app-hosted test product. `xcodebuild` exited 0, but `xcresulttool` reported the test as **Skipped** with the exact message `Set the stable-signer probe environment to run this packaging test.` This proves the values present in the `xcodebuild` process are not forwarded to the launched app-hosted XCTest by the checked-in scheme. The three documented A/deny/B commands can therefore all exit successfully while exercising no Keychain or signing behavior. This defect is independent of the current host's legitimate lack of signing identities.

The phase state machine has a second false-completion path. Create writes only `expected.json`; deny validates A-versus-unrelated metadata and operations but records no successful deny-phase marker or fingerprint; verify requires only that its build ID/path differ from create and that its signer equal create (`ViewerFoundationTests.swift:546-610`). Running create followed directly by verify can pass and remove the state directory without ever running the unrelated-signer phase. Deny and verify are also not mechanically required to use distinct product paths from each other. The newly added designated-requirement inequality correctly prevents a reused A signer from impersonating deny, but it does not close the missing phase transition.

The operation assertions themselves are now proportionate. The unrelated phase calls both production reset APIs and uses the same exact selectors and noninteractive authentication context for direct reads, private-key lookup/use, and deletion (`ViewerFoundationTests.swift:570-585,688-774`). Build A and verify compare team identifier, leaf-certificate hash, and designated requirement; verify also confirms installation ID, certificate hash, and actual signing before authorized resets. The state-root constraint is narrow and only create makes the token directory. These strengths cannot compensate for commands that never enter the test or a verify phase that does not prove deny completed.

The documented fixed token `release-candidate` further conflicts with the remediation claim of a unique per-run token and makes stale failed-run state likely to collide. It fails closed when `expected.json` already exists, but it weakens repeatability and cleanup recovery.

**Required resolution:** provide a mechanism that actually injects the four phase values into the app-hosted XCTest process, such as explicit test-action environment entries fed by command-line build settings or a generated `.xctestrun` invocation, and prove with a no-signer dry run that an enabled phase fails closed rather than skipping. Make deny write an authenticated/validated phase record only after every deny check succeeds; make verify require that record, compare the deny designated requirement and product path against both stable products, and reject skipped or reordered phases. Use a freshly generated token per gate run, document safe recovery for stale state, and make the operator gate explicitly fail if any phase is skipped. Then execute the corrected commands with two valid unrelated identities and save exact results before closing the stable-update requirement.

## Verified Correctness and Testing Strengths

- `ViewerAdmissionAttemptCleanup` publishes completion once only after claim completion, core cleanup, and all direct late-channel cleanup. Its `completionPublished` gate prevents duplicate release.
- The release callback removes the exact budget reservation before completing the registry owner. For handed-off attempts, `ViewerAdmissionHandle.cancelAndWait()` additionally waits for that completion before the handoff owner removes its active handle. The stop receipt therefore has a real happens-before edge to zero occupied slots.
- The burst-ingress test now awaits the stop receipt rather than treating the channel cancellation callback as cleanup completion, eliminating the Round 4 scheduling failure.
- `testHandoffCapacityRecyclesAcrossWavesInOneRuntime` genuinely uses one manager: 32 occupied, eight completed and released to 24, eight newly admitted back to 32, one overflow rejected before claim, then one receipt drains 40 channels with exactly one cancellation each.
- Claim-in-progress cancellation continues to retain its reservation through late channel return and direct cancellation. Policy cancellation, timeout, replacement, and placeholder ownership retain the same combined slot until cleanup.
- Stable-signer phase inputs are syntactically bounded; the state root is standardized and constrained to the Viewer container test path; create refuses an existing record; deny now requires a different designated requirement; verify requires the complete A fingerprint.
- The requirement-to-evidence audit continues to mark cross-update signing evidence pending rather than treating the ordinary conditional skip as proof.

## Independent Validation

- Fresh current-state Viewer app-hosted XCTest: **PASS with one explicit skip**. The final `xcresult` reported 55 passed, 1 skipped, 0 failed, 0 expected failures, and overall result `Passed`.
- Focused cleanup-receipt and same-runtime recycling selection with 20 repetitions: **PASS**. The result recorded 40 passed device/configuration test runs, 0 failed, and 0 skipped.
- Current documented-form signer probe against the app-hosted test product: `xcodebuild` exit 0, but the sole selected test was **Skipped** because the phase environment was absent in the test process.
- `security find-identity -v -p codesigning`: exit 0 with `0 valid identities found`; no external stable-signer behavior is claimed.
- `DO_NOT_TRACK=1 openspec validate viewer-application-foundation --strict --no-interactive`: **PASS**.
- `git diff --check`: **PASS**.

## Verdict

**Approval withheld. Exact unresolved actionable finding count: 1 — 0 High, 1 Medium, and 0 Low.**
