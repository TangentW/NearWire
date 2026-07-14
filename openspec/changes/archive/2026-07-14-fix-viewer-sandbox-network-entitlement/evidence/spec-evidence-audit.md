# Spec-to-Evidence Audit

Date: 2026-07-15 (Asia/Shanghai)

## Viewer Sandbox Profile

- Requirement: App Sandbox includes network-server and network-client.
- Implementation: `Viewer/NearWireViewer/Resources/NearWireViewer.entitlements`.
- Automated evidence: the signed-process entitlement regression passed.
- Packaging evidence: the standalone signed product contains App Sandbox, network-client, and
  network-server, plus only the expected Debug `get-task-allow` entitlement.

## Unrelated Capability Exclusion

- Requirement: no multicast, Keychain-sharing, application-group, or background-service
  entitlements.
- Automated evidence: the signed-process regression checks multicast, Keychain-sharing, and
  application-group absence.
- Packaging evidence: standalone `codesign` inspection found no unrelated capability.

## Local Discovery and Privacy Metadata

- Requirement: `_nearwire._tcp`, the fixed local-network usage description, and the Viewer privacy
  manifest remain packaged.
- Evidence: standalone Info.plist inspection and privacy-manifest lint passed with the exact
  expected values.

## Sandboxed iPhone Connection

- Requirement: the accepted Network.framework flow reaches mandatory TLS.
- Evidence: the server-only sandbox baseline failed at `NECP_CLIENT_ACTION_ADD_FLOW`; the exact
  server-plus-client sandbox profile added the flow, accepted inbound TCP, and completed TLS 1.3
  with ALPN `nearwire/1` on the real iPhone test.

## Regression and Compatibility

- Complete signed Viewer suite: 398 total, 396 passed, 2 skipped, 0 failed.
- Swift 5/macOS 13 build settings and runtime source are unchanged.
- No Core, SDK, public API, wire, storage, dependency, or performance behavior changed.

Every modified requirement and scenario has direct implementation and evidence. No unresolved
finding or completion limitation remains. Signing team selection was supplied only on the command
line and is not part of the repository diff.
