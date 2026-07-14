# Spec-to-Evidence Audit

Date: 2026-07-15 (Asia/Shanghai)

| Requirement or scenario | Implementation evidence | Test evidence | Result |
| --- | --- | --- | --- |
| Decode peer Hello offers above the local session limit | `WireHello` validates the scalar offer against `WireFrameLimits.hardMaximumPayloadBytes` | `testPeerHelloOfferAboveLocalSessionLimitDecodesAndNegotiatesConservatively` | Pass |
| Reject offers above the 16 MiB wire hard bound | The same `WireHello` guard retains a finite upper bound | `testHelloOfferAboveWireHardBoundIsRejected` | Pass |
| Negotiate the smaller offer and retain the local session limit | `WireNegotiator` still selects `min`; `WireSessionCodec` still checks `baseLimits` | Core regression constructs the negotiated session codec at the local limit | Pass |
| Production SDK offer reaches Viewer handoff | Viewer admission itself is unchanged; only the shared pre-handshake scalar validation changed | `testAdmissionManagerHandsOffProductionSDKEventRecordOffer` drives `ViewerAdmissionManager` through automatic handoff | Pass |
| No offered-size allocation during Hello decoding | The changed path compares one `Int`; no frame, queue, storage, or transport capacity is constructed from the peer offer | Focused Core and Viewer tests use the production offer without creating a maximum-sized Event | Pass |
| Dynamic Event sizing remains unchanged | Event payloads continue to encode their actual JSON byte count; this change does not pad, truncate, split, or preallocate Event content | Existing Event, queue, transport, and complete package suites pass | Pass |
| The 256 KiB Event-content maximum is not expanded | `EventValidationLimits.default.maximumEncodedContentBytes` and public SDK buffer defaults remain 262,144 bytes in this change | Complete package and Viewer suites pass with their existing boundary coverage | Pass |

All added requirements and scenarios have direct implementation and test evidence. The only full
Viewer-suite limitation is the separately documented signing-only entitlement assertion for an
intentionally unsigned build.
