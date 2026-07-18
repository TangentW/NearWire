# Design

## One canonical authority

`PairingCode.canonicalLength` changes from six to four. Core parsing, Viewer generation, SDK
connection validation, and Bonjour instance derivation continue to depend on that shared value.
Code outside Core must not introduce another canonical-length constant.

The alphabet remains `ABCDEFGHJKMNPQRSTUVWXYZ23456789`. Four positions provide `31^4 = 923,521`
possible values. This is sufficient for the intended nearby internal-tool discovery scope, and is
not represented as authentication entropy. Existing Viewer publication collision retries and SDK
ambiguity handling remain unchanged.

## Boundary audit

- Core tests use four-character canonical values and separately exercise short and overlong input.
- SDK discovery, admission, lifecycle, and safe-error fixtures use four-character values.
- SDK error guidance derives the displayed numeric length from the Core SPI constant.
- `NearWireUI` continues to retain at most 64 UTF-8 bytes and forwards raw input only on user
  activation. It must not pre-validate or truncate to four characters because Core owns separator,
  case, alphabet, and exact-length normalization.
- Viewer generation continues unbiased rejection sampling until the shared canonical length is
  reached.
- Viewer and test listener fixtures use exact `NearWire-<four-character-code>` instance names.
- Demo contains no canonical-length parser; its integration and UI coverage must continue to compile
  against the updated SDK/UI products.

## Viewer presentation

The listening pairing code remains monospaced, semibold, selectable, and accessibility-labelled.
Its point size increases from 30 to 36. The compact `Pairing Code` caption, status, Copy, Refresh,
Pause/Resume, and trailing approval control remain in the same header row.

## Compatibility

Pairing codes are process-lifetime values and are never persisted, so there is no data migration.
The grammar change is intentionally not dual-length: accepting six characters would retain the old
contract and create inconsistent discovery behavior. Apps and Viewer builds must use the same
NearWire version.

## Validation

- Strict OpenSpec validation before implementation and after archival.
- Exhaustive repository scans for six-character prose and maintained six-character fixtures.
- Core pairing grammar and Bonjour tests.
- SDK discovery, admission, lifecycle, public error, and SDK UI tests.
- Viewer generator, listener replacement, layout/render, and full maintained Viewer tests.
- Root Swift Package Release build and CocoaPods metadata/lint.
- Independent architecture/API, correctness/testing, and security/performance/documentation review,
  followed by a fresh no-findings round.
