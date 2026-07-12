# Implementation Review Round 7 — Architecture and API

## Review Scope

This was a narrow fresh review of the current `viewer-application-foundation` state after the Round 6 product-path remediation. It re-read the current stable-signer probe, its signed-host identity helpers and record model, active design/documentation/evidence wording, the Round 6 architecture report, and the surrounding project/API boundaries. It also ran a fresh complete Viewer test build and proportionate artifact gates.

## Round 6 Finding Verification

| Round 6 finding | Round 7 result |
| --- | --- |
| The recorded `productPath` came from the XCTest bundle while artifacts called it the signed host path | **Resolved.** The probe now reads `productPath` from `Bundle.main.bundleURL.path` (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:554`). The same `Bundle.main` supplies the signed probe configuration and `CFBundleVersion` (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:523-553`), while `SecCodeCopySelf` and `SecCodeCopyStaticCode` fingerprint the executable of that running app-host process (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:648-699`). The path, signed Info.plist values, Code Directory hash, team, certificate, and designated requirement therefore describe one coherent signed `NearWire.app` host rather than mixing host metadata with the injected test bundle. |

## Regression Audit

No new actionable architecture or API finding was identified.

- Create records the actual host-app path together with the host's signed bundle version, Code Directory hash, stable signer fingerprint, signed build ID, and original Keychain identity state (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:556-581`).
- Deny and verify compare their actual host-app paths against create in addition to the independent signed version and Code Directory guards (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:583-611`). A separate DerivedData build can no longer satisfy the path check merely through a different injected XCTest bundle while reusing the same host location.
- The path correction does not alter phase transport, Keychain selectors, reset behavior, signing metadata extraction, the post-denial marker, or the fail-fast operator sequence.
- Reserved build settings still enter through the signed app Info.plist; ordinary builds leave the phase empty and retain the single explicit conditional skip.
- The product-path field name and the active design, documentation, validation evidence, and audit descriptions are now semantically accurate: each refers to the signed app host.
- Connection-owner cleanup remains unchanged and approved: release precedes registry/handle/receipt completion, accepted handles retain cleanup ownership, same-runtime refill remains bounded, and the future session owner retains the original core and finite slot.
- No public SDK API, Core/Viewer ownership, root package/podspec boundary, project dependency, entitlement, privacy resource, or later-change scope changed as part of this remediation.

## Independent Validation

| Command | Result |
| --- | --- |
| Fresh full Viewer app-hosted XCTest with a new DerivedData path and explicit ad-hoc test override | Exit 0; complete ordinary suite passed and the conditional stable-signer gate remained the intentional skip |
| `DO_NOT_TRACK=1 openspec validate viewer-application-foundation --strict --no-interactive` | Passed |
| `swift format lint --strict Viewer/NearWireViewerTests/ViewerFoundationTests.swift` | Passed |
| `git diff --check` | Passed |

The real three-product Keychain gate remains pending because the current host does not provide two valid unrelated signing identities. This review does not infer cross-update behavior from the ad-hoc regression run.

## Verdict

**Approved.** The Round 6 product-path mismatch is closed, the recorded path and Security.framework fingerprint now refer to the same signed app host, and the narrow remediation introduced no architecture, API, lifecycle, project, or packaging regression.

**Exact unresolved actionable finding count: 0.**
