# Independent Review Rounds

Date: 2026-07-19

## Round 1

Three independent reviewers covered architecture/API, correctness/testing, and
security/performance/documentation/UI.

Actionable findings and resolutions:

1. Viewer duplicated the canonical alphabet.
   - Resolution: Core now exposes `PairingCode.canonicalAlphabet` through repository-only SPI, and
     Viewer generation consumes it.
2. SDK invalid-code guidance hardcoded the word `four`.
   - Resolution: the message now interpolates `PairingCode.canonicalLength`.
3. README quick-start examples still used the old six-character `N7K4PX` value.
   - Resolution: both READMEs now use the valid four-character `N7K4` value.
4. The README image showed an obsolete six-character code and older layout.
   - Resolution: the image now shows the current full Viewer window, a prominent four-character
     code, richer image-only event data, and the expanded Viewer-to-App composer.

## Round 2

The fresh round identified two evidence/packaging findings:

1. The SDK imported `NearWireCore` unconditionally after centralizing the error length.
   - Resolution: the SPI import is guarded by `#if SWIFT_PACKAGE`, matching the existing source
     layout. Full Swift tests and CocoaPods lint both passed after this correction.
2. The residue audit recorded the wrong no-match `rg` exit code and described alphabet substrings
   imprecisely.
   - Resolution: the audit now records expected exit code `1` with empty output and distinguishes
     exact quoted fixtures from substrings that naturally occur in the canonical alphabet.

## Fresh final round

All three reviewers reran their assigned review from the corrected final diff:

- Architecture/API/packaging: no actionable findings.
- Correctness/testing: no actionable findings.
- Security/performance/documentation/UI/evidence: no actionable findings.
