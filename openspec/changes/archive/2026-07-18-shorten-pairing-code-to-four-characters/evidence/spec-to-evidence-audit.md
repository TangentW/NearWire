# Spec-to-Evidence Audit

Date: 2026-07-19

## SDK pairing-code capability

| Requirement or scenario | Implementation and evidence |
| --- | --- |
| Exactly four canonical bytes from the supported alphabet | `PairingCode.canonicalLength` is `4`; Core pairing tests cover valid, short, overlong, invalid, separator-heavy, and normalized input. The complete Swift suite passed 556 tests. |
| Bounded normalization and safe non-echoing errors | Existing bounded parser behavior is preserved; focused Core and SDK public-error tests passed. SDK guidance derives the numeric length from Core. |
| Exact `NearWire-<code>` Bonjour instance | Discovery and listener fixtures use four-character values; exact name, conflict suffix, and mismatch behavior remain covered by the complete Swift and Viewer suites. |
| No duplicate six-character SDK UI or Demo contract | The source/configuration audit found no canonical-length parser or constant in NearWireUI or Demo. Demo builds through the updated products. |

## Viewer application foundation capability

| Requirement or scenario | Implementation and evidence |
| --- | --- |
| Four-character unbiased generation from one canonical alphabet | Viewer generation consumes Core's canonical length and alphabet. Its focused generator test and maintained Viewer suite passed. |
| Ephemeral exact publication | Existing listener lifecycle and exact-name registration behavior is unchanged; updated four-character fixtures pass the Viewer and Swift suites. |
| Prominent 36-point code without clipping | `ViewerRootView` uses a 36-point monospaced semibold font. Focused supported-size, appearance, and minimum-width layout tests passed. |
| Current documentation and complete Viewer image | Both READMEs and maintained product docs use four-character examples. The README asset shows the full current Viewer, valid four-character code, and expanded Viewer-to-App composer; mock content exists only in the image asset. |

## Cross-cutting gates

- SwiftPM: 556 tests passed with zero failures; release build passed.
- CocoaPods: `pod ipc spec` and `pod lib lint --allow-warnings --skip-tests` passed.
- Viewer: focused layout/generator checks and the maintained suite passed under the documented
  existing exclusions.
- Demo: generic iOS Simulator build passed.
- Hygiene: formatting checks for changed focused files and `git diff --check` passed.
- Residue: contextual six-character and old-prose scans returned no matches.
- Reviews: three independent areas completed a final fresh round with no actionable findings.

Every changed capability requirement and scenario has implementation and proportionate validation
evidence. No unresolved finding or unverified in-scope requirement remains.
