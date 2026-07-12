# Implementation Review Round 3 Remediation

Date: 2026-07-12

## Finding Status

| Round 3 finding | Current resolution | Evidence status |
| --- | --- | --- |
| Stable login-Keychain access was incorrectly claimed for ad-hoc updates | The maintained project now defaults to automatic `Apple Development` signing. The active proposal, design, spec, task plan, Viewer README, and operator documentation require one stable Apple Development signer for internal updates or Developer ID for distributed updates. Ad-hoc signing is limited to isolated unit tests and structural product inspection. A conditional update-boundary XCTest probe creates identity in build A, verifies the same installation/certificate and a real private-key signing operation in build B, exercises TLS-only and full reset, and has an unrelated-signer denial phase. | **Pending external signing identity.** This host has no valid code-signing identity. The ordinary suite transparently skips only this packaging probe. A temporary self-signed trust-root approach was rejected by the execution safety policy; its temporary keychains and private-key files were deleted without installing a trust entry. The stable-signer gate must run before this finding can be closed. |
| Cleanup and placeholder ownership escaped the 32-slot admission bound | Admission reservations are now released only by per-attempt cleanup completion. They remain occupied through claim completion, direct late-channel cleanup, asynchronous core cancellation, placeholder handoff ownership, and owner shutdown. The decision deadline still selects handoff-or-cancel at ten seconds, while delayed cleanup retains the same finite slot. | **Resolved locally.** `testCombinedAdmissionBoundIncludesCancellingAndPlaceholderOwnedConnections` gates 32 cancellations and 32 automatic placeholder handoffs in separate waves, proves the 33rd wrapper is rejected before claim, then proves exact drain and a zero-owner stop receipt. The full Viewer suite reports 54 passed, 1 explicit stable-signer skip, and 0 failures. |

## Proportionality

No validation script was added. Swift behavior remains in XCTest. The only conditional test is an update-boundary integration probe because a same-process unit test cannot establish macOS code-signing ACL behavior across independently signed application builds.
