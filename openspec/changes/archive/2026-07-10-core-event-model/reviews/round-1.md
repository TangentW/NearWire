# Core Event Model Review: Round 1

## Reviewers

- Architecture and API reviewer: completed with four findings.
- Correctness and testing reviewer: completed with three findings.
- Security, performance, and documentation reviewer: completed with three findings.

The independent reports converged on the same core risks. Findings below are deduplicated but preserve every actionable concern.

## Findings and resolutions

### 1. Lossless numeric Codable behavior — P1

**Finding:** Foundation's untagged scalar decoding cannot distinguish integer tokens from integral floating-point values reliably. It can decode `1.0` as `Int64`, while an integer above `Int64.max` can fall through to `Double`. This violated the promised distinct `JSONValue.integer` and `JSONValue.number` semantics and affected draft and envelope Codable round trips.

**Resolution:** `JSONValue` now uses an internal tagged Codable representation with explicit null, Boolean, integer, number, string, array, and object kinds. Plain event-content JSON remains untagged and uses `decodeJSON` plus `deterministicData`. Regression tests cover tagged numeric round trips and an envelope whose content contains `.number(1)`.

### 2. Active validation limits were not composable — P1

**Finding:** Nested `EventType` and `EventTTL` decoding selected defaults independently, aggregate draft and envelope decoding could not install negotiated limits, and type length was not revalidated at draft or envelope construction. The type-limit hard range also contradicted the fixed 128-byte product rule.

**Resolution:** One validation-limit set now travels through decoder user information. `EventDraft.decode`, `EventEnvelope.decode`, and `EventContentCodec` install it for every nested value. Drafts and envelopes revalidate event type, content, and TTL at the aggregate boundary. Event-type configuration is capped at 128 bytes. Tests cover a permissive two-day TTL, default rejection of that TTL, a stricter type limit, and nested content-codec propagation.

### 3. Untrusted JSON was parsed before its byte limit — P1/P2

**Finding:** `JSONSerialization` materialized input before any encoded-byte check, permitting oversized or whitespace-padded input to consume avoidable resources before rejection. Canonical encoding also allocated the complete result before checking its limit.

**Resolution:** `decodeJSON` now rejects raw bytes above the active encoded-content cap before parsing. Canonical deterministic encoding checks the cap incrementally during validation rather than building an arbitrarily larger result first. Regression tests cover oversized padded input, canonical encoded-size overflow, and adversarial raw nesting.

### 4. Cross-device monotonic clocks are unrelated — P1

**Finding:** `EventEnvelope.isExpired(at:)` made it easy for a Mac receiver to compare its uptime to an iPhone creation uptime, producing meaningless expiration results.

**Resolution:** The receiver-facing envelope convenience was removed. The pure TTL operation now labels its input `nowOnCreationClockNanoseconds`, and documentation and design explicitly restrict that operation to origin-local queue state. The future wire protocol must transmit or establish receiver-local remaining lifetime rather than compare device uptimes.

## Regression result

After the resolutions, the focused NearWireCore suite passed 27 tests with zero failures. Full canonical compatibility evidence will be recaptured after a fresh zero-finding review round so the evidence describes the final source.

## Round status

All round-1 findings are resolved in source, tests, design, and documentation. A fresh independent review is required; this round is not a completion approval.
