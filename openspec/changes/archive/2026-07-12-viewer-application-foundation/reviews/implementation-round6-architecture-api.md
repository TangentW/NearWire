# Implementation Review Round 6 — Architecture and API

## Review Scope

This was a fresh review of the current `viewer-application-foundation` worktree after Round 5 remediation. It re-read the active artifacts, all Round 5 reports, current Viewer production/test source, the manual project and signed resources, operator documentation, validation evidence, and requirement audit. The focused audit traced reserved build settings into the signed app Info.plist and app-hosted XCTest, checked signed bundle/build identity and deny-to-verify sequencing, and rechecked the connection-owner and repository/API boundaries.

## Round 5 Finding Verification

| Round 5 finding | Round 6 result |
| --- | --- |
| Shell-prefixed probe variables did not reach app-hosted XCTest | **Resolved.** The four reserved `NEARWIRE_SIGNER_PROBE_*` build settings expand into the app target's processed Info.plist, and the test reads them from `Bundle.main.infoDictionary` (`Viewer/NearWireViewer/Resources/Info.plist:29-36`; `Viewer/NearWireViewerTests/ViewerFoundationTests.swift:523-542`). The saved safe invalid-phase run proves a nonempty signed phase reaches the test and fails rather than taking the ordinary skip branch (`evidence/implementation-validation.md:56-62`). Normal builds leave the reserved fields empty and preserve the single explicit conditional skip. |
| Verify did not require successful unrelated-signer denial | **Resolved for the documented operator gate.** The test requires `deny-complete` before verify (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:548,602-611`). The documented commands run in one shell under `set -e`; the shell creates that marker only after the deny `xcodebuild test` exits successfully, so a deny assertion, signing, build, or test-launch failure prevents both marker creation and verify (`Documentation/Viewer-Foundation.md:19-34`). Create rejects stale expected state, deny rejects a pre-existing marker, and verify removes token state only after authorized resets. |
| A/B distinction relied only on operator labels and XCTest bundle paths | **Substantially resolved.** Phase/build/token/state inputs are now signed Info.plist values rather than forwarded environment text. A, deny, and B use distinct signed `CFBundleVersion` values, and the test records the actual running host's Security.framework Code Directory hash, team, certificate hash, and designated requirement. Deny requires different signed version/CDHash and unrelated requirement; verify requires different signed version/CDHash while matching the complete stable signer (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:549-611,648-699`). One residual path-label mismatch remains below. |

## Finding

### 1. Low — The recorded `productPath` is still the XCTest bundle path while artifacts call it the signed host product path

The probe correctly reads signed configuration and `CFBundleVersion` from `Bundle.main`, and `SecCodeCopySelf` fingerprints the actual app-host process. However, `productPath` is populated with `Bundle(for: Self.self).bundleURL.path` (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:554`), which is the `NearWireViewerTests.xctest` bundle containing the test class, not `NearWire.app`. Create records that value and deny/verify compare it (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:567-580,583-608`).

The design says the test records the signed host product path (`openspec/changes/viewer-application-foundation/design.md:49`), operator documentation repeats “signed host ... product path” (`Documentation/Viewer-Foundation.md:19`), and evidence says reused signed host paths are rejected (`openspec/changes/viewer-application-foundation/evidence/implementation-validation.md:54`). Those claims are not exact. Separate DerivedData paths do make the XCTest bundle paths differ, and the signed host's distinct `CFBundleVersion` plus Code Directory hash already provide the important mechanical A/B proof, so this does not reopen the stable-signing design or permit a same-host build to pass. It is nevertheless an actionable evidence/API-of-the-gate mismatch.

**Required remediation:** record and compare `Bundle.main.bundleURL.path` as the host product path. If retaining the test-bundle path is useful, store it separately with an accurate name rather than representing it as the host. Update the record field and affected wording, then rerun the ordinary suite and safe signed-Info forwarding probe.

## Architecture and API Checks That Passed

- Reserved Info.plist keys are internal packaging-gate transport, not public SDK API. Normal builds expand them to empty values; they carry no Keychain material, certificate data, or App event content.
- Signed `CFBundleVersion`, host Code Directory hash, signed build ID, and signer fingerprint form a fail-closed build identity. Operator-provided identity/team values are not trusted as runtime proof.
- Deny requires a distinct signed version, Code Directory, test product, composite signer, and designated requirement before destructive checks. Verify requires the original stable signer and distinct signed build before identity reload or reset.
- The post-denial marker is non-sensitive control state. Under the documented single-shell `set -e` sequence it cannot be created by a skipped or failed deny command; missing or stale/reordered marker state fails closed.
- Exact unrelated-signer load, signing use, both reset APIs, exact reads, and exact deletions remain covered. External ACL execution correctly remains pending because this host has no valid signing identities.
- Connection cleanup remains correct: one guarded attempt completion releases the exact reservation before registry/handle/receipt completion; accepted handles retain cleanup ownership; same-runtime partial drain/refill remains bounded at 32; the future session-owner boundary retains the original core and finite slot.
- Core/Viewer/SDK ownership, manual Xcode project, Swift 5/macOS 13 compatibility, automatic maintained signing, root manifest/podspec boundaries, Apple-only Viewer runtime dependencies, privacy metadata, and later-change exclusions remain acceptable.

## Independent Validation

| Check | Result |
| --- | --- |
| Fresh full Viewer app-hosted XCTest with a new DerivedData path and explicit ad-hoc test override | Exit 0; ordinary suite passed and the signed-phase-empty packaging gate remained the intentional skip |
| Saved safe invalid-phase signed-Info transport check | Expected exit 65 with the selected test failing rather than skipping; built host Info.plist recorded `NearWireSignerProbePhase=invalid` |
| Current source/artifact inspection | Signed Info fields, `CFBundleVersion`, Code Directory fingerprint, signer guards, marker sequencing, and project boundaries verified as described above |

The real A/unrelated/B Keychain gate remains unexecuted because the host has no two valid unrelated signing identities. No cross-update result is inferred from ad-hoc validation.

## Verdict

**Approval withheld.** The Round 5 false-skip, signed-build identity, and deny-before-verify defects are architecturally closed, and connection cleanup remains approved. One low-severity mismatch remains between the recorded XCTest bundle path and the artifacts' claimed signed host product path.

**Exact unresolved actionable finding count: 1** — 0 High, 0 Medium, 1 Low.
