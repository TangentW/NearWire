# Implementation Review Round 6 Remediation

Date: 2026-07-12

## Resolved Findings

The Round 5 signer-gate command defect is resolved without adding a script. Reserved Info.plist fields bind the four probe build settings into the signed app host. A safe invalid-phase command exited 65 with a failed XCTest instead of silently skipping, and the built Info.plist contained the invalid phase value. Normal builds leave the reserved fields empty and retain one explicit conditional skip.

The three products now carry distinct signed bundle versions, Code Directory hashes, host app paths, and operator build identifiers. The same-signer phases must match team, signing certificate, and designated requirement; the denial phase must have an unrelated designated requirement. A fail-fast operator sequence creates a non-sensitive completion marker only after the denial XCTest succeeds, and verify refuses to run without that marker.

Round 6 architecture review identified one final low-severity evidence-label mismatch: the test recorded the XCTest bundle path while documentation called it the signed host path. The probe now records `Bundle.main.bundleURL.path`, matching the same app host whose signed Info.plist is read and whose executable is fingerprinted through `SecCodeCopySelf`.

## Final Review Status

- Round 7 architecture/API: approved, 0 unresolved actionable findings.
- Round 6 correctness/testing: approved, 0 unresolved actionable findings.
- Round 6 security/performance/documentation: approved, 0 unresolved actionable findings.

The implementation review loop is complete. This host reports zero valid code-signing identities, so the documented A/unrelated/B gate still requires two valid unrelated identities and saved execution results. The user explicitly moved that environment-dependent execution to the mandatory `release-hardening` final-system gate. The executable XCTest and operator recipe remain part of this change, while its archive no longer claims that the external sequence ran.

A final safe fallback check generated two one-day code-signing certificates in isolated temporary Keychains without adding either certificate to a trust domain or changing the default Keychain search list. `security find-identity -v -p codesigning` reported neither as valid, and `codesign` rejected the disposable executable with `no identity found`. Both temporary Keychains, private keys, certificates, and executable were deleted immediately. The user Keychain search list again contains only `login.keychain-db`, and no trust setting was added. NearWire therefore does not substitute a locally trusted test root or ad-hoc signature for the required supported-signer evidence.
