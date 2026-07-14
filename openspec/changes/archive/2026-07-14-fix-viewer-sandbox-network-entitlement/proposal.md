## Why

The sandboxed macOS Viewer advertises and listens successfully, but a real iPhone connection is
rejected by macOS before TLS because the accepted Network.framework flow cannot be added through
NECP. A controlled comparison proved that the same Viewer connects when unsandboxed, and also
connects with App Sandbox preserved when the network-client entitlement is added alongside the
existing network-server entitlement.

## What Changes

- Add the macOS network-client entitlement to the Viewer while preserving App Sandbox and the
  existing network-server entitlement.
- Update the signed-process entitlement regression to require both network capabilities and to
  continue rejecting unrelated network, Keychain-sharing, and application-group capabilities.
- Correct the Viewer foundation documentation and capability specification to describe the exact
  maintained sandbox profile.

## Capabilities

### Modified Capabilities

- `viewer-application-foundation`: Requires both sandbox network entitlements so the published
  listener can accept an iPhone flow and proceed to mandatory TLS.

## Impact

- Changes only Viewer signing metadata, one Viewer entitlement test, and affected documentation.
- Adds no SDK, Core, wire-protocol, dependency, storage, or public API change.
- Does not disable App Sandbox or add multicast, Keychain-sharing, application-group, or
  background-service capabilities.
