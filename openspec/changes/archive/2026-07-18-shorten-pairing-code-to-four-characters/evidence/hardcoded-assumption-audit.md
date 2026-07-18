# Hardcoded-Assumption Audit

Date: 2026-07-19

## Canonical authority

- `Core/Sources/NearWireCore/Discovery/PairingCode.swift` is the only maintained source that
  declares the canonical pairing-code length and alphabet. Its length is `4`.
- Viewer generation reads `PairingCode.canonicalLength` and `PairingCode.canonicalAlphabet`.
- SDK connection validation constructs `PairingCode` and does not declare another length.
- SDK invalid-code guidance interpolates `PairingCode.canonicalLength`.
- `NearWireUI` retains at most 64 UTF-8 input bytes as a defensive raw-input bound. It deliberately
  does not implement canonical length, alphabet, case, or separator validation.
- Demo embeds `NearWireConnectionView` and contains no pairing-code parser or length constant.

## Residue scans

The following scans completed with the expected `rg` exit code `1` and empty output, meaning no
matches were found:

```text
rg -n --pcre2 'PairingCode\("[A-HJ-KM-NP-Z2-9]{5,}"\)' Core SDK Viewer Demo --glob '*.swift'
rg -n --pcre2 'NearWire-[A-HJ-KM-NP-Z2-9]{5,}' Core SDK Viewer Demo --glob '*.{swift,md,pbxproj}'
rg -n --pcre2 'connect\(code:\s*"[A-HJ-KM-NP-Z2-9]{5,}"' Core SDK Viewer Demo Documentation README.md README.zh-CN.md
rg -n --pcre2 '(six[- ]character|six canonical|non-six|六位)' Core SDK Viewer Demo Documentation README.md README.zh-CN.md
```

An exact quoted-token scan found no maintained occurrences of the previous fixtures `ABC234`,
`7K3M9Q`, `MNPQRS`, `TUVWXY`, `N7K4PX`, or `NearWire-OTHER1`. The unquoted substrings `MNPQRS`
and `TUVWXY` naturally occur inside the canonical alphabet and are not pairing-code fixtures.

Archived OpenSpec history is intentionally not rewritten.
