# Implementation Review Round 6: Security, Performance, and Documentation

## Scope and Verdict

This fresh review re-read the complete current `viewer-application-foundation` worktree after Round 5 remediation: active artifacts, Viewer and changed Core production source, tests, signed-host project configuration, resources, operator documentation, validation evidence, requirement-to-evidence audit, all Round 5 reports, and the current remediation record. No production, specification, task, test, documentation, or evidence artifact was modified; this report is the only added file.

The Round 5 stable-signer gate defect is closed in the current implementation and documented operator procedure. Probe configuration is carried by reserved fields in the signed host Info.plist; the test fingerprints the actual app host and its Code Directory; all destructive denial operations are preceded by strict unrelated-designated-requirement and distinct-build guards; the fail-fast operator sequence creates a non-sensitive completion marker only after the deny XCTest succeeds; verify requires that marker before authorized reset; and normal Release metadata, entitlements, and privacy behavior remain unchanged apart from four empty reserved keys.

No new security, performance, privacy, or documentation defect was identified.

**Exact unresolved actionable finding count: 0.**

**Round 6 security/performance/documentation implementation review is approved.**

The external cross-update behavior is not yet proven on this host because it reports zero valid signing identities. That remains an explicit execution-evidence gate for completing and archiving the change, not an unresolved implementation finding.

## Round 5 Finding Recheck

### `NW-SPD5-001`: verify could skip denial and A/B were not bound to actual signed host builds

**Resolved.**

- The four phase inputs are expanded into `NearWireSignerProbePhase`, `NearWireSignerProbeToken`, `NearWireSignerProbeBuildID`, and `NearWireSignerProbeStateRoot` in the host app's signed Info.plist. The XCTest reads them from `Bundle.main.infoDictionary`, so it no longer depends on shell environment forwarding into an app-hosted XCTest (`Viewer/NearWireViewer/Resources/Info.plist:31-38` and `Viewer/NearWireViewerTests/ViewerFoundationTests.swift:523-542`).
- A safe recorded invalid-phase invocation exited 65 instead of skipping, while an ordinary build with an empty signed phase remains the single deliberate skip. This proves the build-setting-to-signed-host path and its fail-closed behavior (`openspec/changes/viewer-application-foundation/evidence/implementation-validation.md:56-62`).
- Host identity comes from `SecCodeCopySelf`, its static code, designated requirement, signing information, Team ID, leaf signing-certificate hash, and `kSecCodeInfoUnique` Code Directory hash (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:648-700`). The product path now comes from `Bundle.main.bundleURL.path`, and the signed `CFBundleVersion` comes from the same main bundle. No identity or hash comparison trusts the operator's `IDENTITY_*` or `TEAM_*` values as runtime proof.
- Create records the original installation ID, certificate hash/reference, complete stable-signer fingerprint, Code Directory hash, signed bundle version, explicit build label, and signed host product path (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:556-581` and `Viewer/NearWireViewerTests/ViewerFoundationTests.swift:2554-2563`).
- Before any destructive probe, deny requires a different build label, signed host path, signed bundle version, Code Directory hash, composite signer fingerprint, and designated requirement. It also refuses a pre-existing completion marker (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:583-600`). Reusing the stable signer, path, version, or build identity therefore fails before reset or deletion.
- Verify requires a different signed host build, the complete original stable-signer fingerprint, and the post-denial marker before it loads or resets identity material (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:602-628`). It proves the original installation ID, certificate, and real private-key signing use remain intact before exercising TLS-only and full reset.
- The English recipe uses one shell with `set -e`, three separate DerivedData products, distinct signed `CFBundleVersion` values, explicit identities/teams/build labels, and one shared token/state root. The external `touch` occurs immediately after the deny `xcodebuild test`; a deny assertion or test failure exits the shell before marker creation. Create refuses existing state, deny refuses an existing marker, and verify requires the marker, so stale, repeated, and reordered documented runs fail closed (`Documentation/Viewer-Foundation.md:15-34`).

## Security and Safety Audit

### Signed-host probe configuration

The reserved Info.plist fields are part of the signed app host, so phase configuration cannot silently disappear between `xcodebuild` and the XCTest process. Phase is parsed as the closed `create`/`deny`/`verify` enum; token and build labels are bounded to 6–64 ASCII letters, numbers, or hyphens. Missing ordinary configuration produces the explicit packaging skip, while a nonempty invalid phase fails.

The current Release product contains all four reserved keys as empty strings. They expose no token, path, identity, signing material, or user data in a normal product and trigger no probe behavior.

### Actual host identity and distinct builds

Security.framework inspects the currently running app-host process rather than the test bundle or command-line declaration. Team ID, signing leaf, designated requirement, and Code Directory hash collectively distinguish signer policy from exact signed content. Main-bundle path and signed bundle version provide additional independent build checks. Stable A and B require the complete same-signer fingerprint while differing in path, version, Code Directory hash, and explicit build label; deny must also have a different designated requirement.

### Deny safety and exact operation coverage

All identity/build/marker guards run before the first Keychain store call. The deny branch then independently covers:

- production `loadOrCreate` denial;
- production TLS-only and full-reset denial;
- exact non-interactive reads of `installation-id` and `tls-metadata`;
- exact private-key tag/class/type lookup and real signing-use denial;
- exact generic-password, private-key, and persistent-reference certificate deletion denial.

Every direct query uses an `LAContext` with interaction disabled, synchronization false, the file-based Keychain flag, and the same isolated production-mode selectors as the store. XCTest assertion failures make `xcodebuild` fail; `set -e` prevents the external completion marker and final stable phase from running. If a denial unexpectedly mutates state, no marker is produced and the retained fixture remains available for investigation.

### Completion marker and state root

The completion marker is deliberately non-sensitive and external. It is not treated as a signing credential or authorization token; its only purpose is to bind the trusted operator's fail-fast command sequence to the verify precondition. Deny refuses a pre-existing marker, and verify checks it before any authorized destructive operation. The recipe's command ordering prevents automatic marker creation after a failed or skipped enabled denial phase.

The state root must be standardized, end in `nearwire-viewer-stable-signer-probe`, and lie under the Viewer container temporary-path shape. Token validation prevents path traversal. The app's sandbox further prevents probe writes outside its allowed container. Only create creates the token directory, deny consumes existing fixture state, and successful verify removes the token-scoped directory after full reset.

### Normal release, privacy, and proportionality

A fresh ad-hoc Release build verified successfully. Its final Info.plist contains the expected macOS 13, product/version, Bonjour, and local-network metadata plus four empty reserved probe strings. Its entitlements remain exactly App Sandbox and incoming network server. Its packaged privacy manifest remains tracking false, declares linked Device ID solely for App functionality, and contains only the UserDefaults reason `CA92.1`. The probe adds no collected-data category, tracking domain, entitlement, runtime service, production dependency, background behavior, or user-visible state.

Keeping the release-only integration behavior in one conditional app-hosted XCTest with an English command recipe is proportionate. No new shell script, project generator, package dependency, Viewer runtime framework, or root-manifest entry was added.

## Performance and Finite-Resource Recheck

- The one runtime-wide 32-owner reservation remains held through claim, pre-Hello, approval, cancellation, direct late-channel cleanup, active placeholder handoff, and cleanup publication.
- Cleanup publishes only after the exact reservation is released and registry ownership is removed. Accepted handle shutdown waits for both core cleanup and that completion edge.
- The deterministic same-runtime 32→24→32 recycle/overflow test, combined cancellation/placeholder bound, and receipt ordering remain present and passing in current saved evidence.
- Synchronous ingress, bounded continuous decoding, latest-only pending-state coalescing, and generation deactivation retain the established backpressure and memory bounds.

No Round 6 resource regression or documentation contradiction was found.

## Fresh Validation Performed

All commands were run from the repository root on 2026-07-12.

1. Current ad-hoc Release build with a fresh DerivedData path:
   - Result: exit 0.
2. `codesign --verify --deep --strict --verbose=2` on the fresh Release app:
   - Result: valid on disk and satisfies its Designated Requirement.
3. `codesign -d --entitlements -` on the fresh Release app:
   - Result: exactly `com.apple.security.app-sandbox=true` and `com.apple.security.network.server=true`.
4. `plutil -p` on the final Info.plist and privacy manifest:
   - Result: normal probe fields are empty; product/local-network metadata and privacy declarations match the active contract.
5. `security find-identity -v -p codesigning`:
   - Result: exit 0 with `0 valid identities found`.
6. `DO_NOT_TRACK=1 openspec validate viewer-application-foundation --strict --no-interactive`, `./Scripts/verify-english.sh`, and `git diff --check`:
   - Result: all passed.

The active validation record additionally reports the current complete Viewer suite at 55 passed, one explicit conditional signer skip, and zero failed, plus the safe invalid-phase forwarding check at the expected exit 65. This review does not convert either the ordinary skip or the ad-hoc Release inspection into cross-update Keychain evidence.

## Completion Gate

**Approved with zero unresolved implementation findings.** The signed-host gate configuration, actual host identity/hash checks, deny safety, exact operation coverage, external marker sequencing, state-root handling, normal Release metadata/privacy behavior, finite-resource ownership, and no-new-script packaging approach are coherent.

The change must nevertheless remain active until the documented create/deny/marker/verify sequence is executed with two valid unrelated code-signing identities and the exact results are saved. That is the remaining external evidence gate; it is not an implementation defect and does not change this Round 6 approval.
