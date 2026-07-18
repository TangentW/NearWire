# Change: Shorten Pairing Codes to Four Characters

## Why

NearWire pairing codes are ephemeral Bonjour discovery selectors rather than passwords or Viewer
identity credentials. For an internal tool, the current six-character code adds manual-entry cost
without materially strengthening transport security. The canonical 31-character alphabet still
provides 923,521 four-character combinations, while existing exact-registration and ambiguous
discovery handling remain responsible for accidental collisions.

## What Changes

- Change the one canonical Core pairing-code grammar from six characters to four.
- Keep the existing 31-character alphabet, 64-byte raw-input work bound, normalization rules,
  redaction, Bonjour identity derivation, and non-persistence behavior.
- Make the Viewer generator emit four unbiased random characters through the shared canonical
  length.
- Update SDK validation guidance and every maintained Core, SDK, SDK UI, Viewer, and Demo fixture or
  assertion that assumes a six-character canonical value.
- Keep `NearWireUI`'s 64-byte raw-input limiter; it deliberately does not duplicate Core grammar.
- Increase the Viewer pairing-code presentation from 30 to 36 points while preserving its header
  layout and accessibility behavior.
- Update current product documentation and READMEs. Historical archived OpenSpec records remain
  unchanged.

## Impact

- A new SDK rejects six-character codes and a new Viewer advertises only four-character codes.
  Mixed old/new versions cannot pair and must be upgraded together.
- No stored data migration is needed because pairing codes are not persisted.
- TLS encryption, Viewer identity behavior, approval policy, active sessions, and Event transfer are
  unchanged.
