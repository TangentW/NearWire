# Core Event Model Review: Round 3

## Result

- Architecture and API: zero findings.
- Correctness and testing: zero findings.
- Security, performance, and documentation: two findings.

## Findings and resolutions

### 1. Verbose tagged representation could exceed the model cap — P1

The security reviewer constructed valid default-limit content containing 31 arrays of 4,096 integer zeros. Its plain deterministic form uses 254,015 bytes, but the verbose keyed tags expanded beyond the 1 MiB model cap, so a valid envelope could encode but fail its own decode helper.

`JSONValue` now uses compact numeric unkeyed tags. The default internal model cap is 2 MiB, and limit construction requires the model cap to be at least four times the content cap plus 64 KiB for tags and fixed fields. The hard model cap increased to 128 MiB so it can satisfy that relationship at the hard 16 MiB content cap. A regression test constructs the exact 254,015-byte many-small-scalars payload and proves full envelope round-trip under defaults.

### 2. Floating-point syntax documentation was too specific — P3

The documentation promised a decimal marker for integral floating-point values even though deterministic formatting may use exponent syntax. It now states that a decimal point or exponent preserves floating-point intent as appropriate.

## Regression result

The focused NearWireCore suite passes 29 tests with zero failures, including the near-limit compact-tag round trip. Another fresh three-perspective review is required.
