# Core Event Model Review: Round 2

## Result

Fresh review after round-1 remediation found four remaining issues across the three perspectives. All were resolved before requesting another fresh round.

## Findings and resolutions

### 1. Same-clock requirement remained ambiguous — P2

Architecture and documentation reviewers found that the main documentation and normative scenario still referred to a generic current monotonic value. The documentation and specification now require the value to come from the exact clock that produced the creation timestamp, explicitly prohibit Mac-to-iPhone uptime comparison, and assign receiver-local remaining lifetime to the future wire protocol. Wall time is now described as approximate display context rather than authoritative cross-device ordering.

### 2. Very large lexical integers could become rounded doubles — P1

The correctness reviewer demonstrated that Foundation represents some integer tokens beyond `UInt64` as `NSNumber` doubles. Classifying only by `objCType` therefore accepted rounded values as floating-point numbers. Plain JSON now receives a string-aware lexical preflight that recognizes JSON number tokens outside strings and rejects every integral token that cannot initialize `Int64` before Foundation conversion. Decimal and exponent tokens remain finite floating-point values. Regression fixtures include both signed boundaries, values beyond `UInt64`, a much larger integer, decimal form, and exponent form.

### 3. Tagged aggregate input lacked pre-materialization bounds — P1

The security reviewer found that the new aggregate decode helpers could materialize oversized ignored fields or excessively nested tagged content before semantic validation. `EventValidationLimits` now includes a 1 MiB default internal model-data cap, which must be at least the content cap. Plain and tagged JSON receive byte and nesting preflight before Foundation decoding. Aggregate tests cover oversized ignored fields and excessive tagged nesting.

### 4. Canonical evidence predated remediation — P2

The security reviewer correctly noted that the canonical evidence run was no longer authoritative after source changes. Full evidence will be recaptured only after the next fresh review reaches zero findings, and the final summary will reference that later run rather than the obsolete round-1 run.

## Regression result

The focused NearWireCore suite now passes 28 tests with zero failures. This round remains non-final because every remediation requires a fresh review.
