## Why

NearWire now has the shared protocol, mandatory-TLS transport, iOS connection facade, UI, and optional performance sender, but it still has no runnable macOS Viewer. This change creates the smallest useful native Viewer foundation so later multi-device, storage, explorer, and performance work can build on a real window-owned listener instead of another test harness.

## What Changes

- Add a manually maintained `Viewer/NearWireViewer.xcodeproj` containing the native macOS 13 SwiftUI application and unit-test target. The user-visible product is `NearWire`; the Swift module and project remain `NearWireViewer`.
- Reference the Viewer project from the root workspace without adding a nested package manifest, podspec, project generator, or root Swift Package dependency.
- Add a single-window application coordinator that starts when the window opens, stops when the last window closes, and exposes bounded starting, listening, paused, stopping, and failed presentation state.
- Add a Viewer-owned macOS login-Keychain lifecycle for a random installation ID and reusable self-signed TLS `SecIdentity`, protected by the maintained app's stable Apple Development or Developer ID signing requirement, including fail-closed load/create behavior, explicit TLS-only reset, and confirmed full Viewer-identity reset.
- Generate one non-persistent six-character pairing code with `SecRandomCopyBytes`, publish `NearWire-<code>._nearwire._tcp` only after identity readiness, include only the validated `vid` TXT value, and detect registration rename/conflict before showing the code as usable.
- Extend the existing mandatory-TLS Viewer listener wrapper only enough to configure and observe Bonjour service registration while continuing to hide raw `NWListener` and accepted `NWConnection` values.
- Add bounded pre-session admission: automatic handoff by default, optional user confirmation, pause/resume for new devices, one runtime-wide 32-slot connection-owner bound retained from pre-Hello through cleanup, one 10-second decision deadline, safe App-summary presentation, one permanent connection owner, and exact cancellation on listener/window shutdown.
- Add the exact App Sandbox server entitlement, local-network/Bonjour declarations, Viewer-owned privacy manifest, and nearby-discoverability disclosure required by the runtime behavior.
- Keep active multi-device sessions, flow-policy execution, Event transfer, persistence, search, the three-column explorer, control composition, and performance charts out of this change.

## Capabilities

### New Capabilities

- `viewer-application-foundation`: Native Viewer project, window-owned runtime, persistent Viewer identities, pairing publication, and bounded connection admission.

### Modified Capabilities

- `repository-structure`: The committed Viewer project becomes the first real project referenced by the existing root workspace while Demo remains a later change.

## Impact

The change affects `Viewer`, the root workspace, the internal Core secure Viewer listener surface, related Core and Viewer tests, project/build validation, documentation, and OpenSpec evidence. Viewer links the repository-local `NearWireCore` product and Apple frameworks only; it introduces no third-party runtime dependency and does not change the root `Package.swift` or `NearWire.podspec`.
