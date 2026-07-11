# API and Distribution Boundary Inventory

## Supported Surface

The active-pump change adds **zero supported SDK declarations**. All new SDK types are unannotated repository-internal implementation types. The root Swift package manifest and root podspec have no diff, so the supported products, targets, subspecs, deployment targets, and dependencies are unchanged.

Commands:

```text
git diff -- Package.swift NearWire.podspec
```

Result: no output.

The internal SDK implementation now also binds one `SDKActiveLiveOperations` value to the exact active owner, secure channel, session clock, and operation gate. Its typed closures and test hooks are unannotated internal declarations and do not add SPI or supported API.

```text
rg '^(@_spi\(NearWireInternal\) )?(public|open) ' \
  SDK/Sources/NearWire/Session/SDKActiveEventPump.swift \
  SDK/Sources/NearWire/Session/SDKActiveOperationGate.swift \
  SDK/Sources/NearWire/Session/SDKIncomingEventQueue.swift \
  SDK/Sources/NearWire/Session/SDKOutboundQueueIntegration.swift
```

Result: no output.

## Internal Core SPI Delta

The only declaration-level Core additions are explicitly tagged `@_spi(NearWireInternal)` or members of those SPI types:

- active queue scheduling observation and offer result;
- active queue observation and offering operations;
- prevalidated token consumption;
- secure-mailbox capacity snapshot, reserved synchronous admission, capacity predicate, and progress generation;
- bounded frame-decoder consumption;
- deterministic internal Event-record byte measurement and maximum fully framed single-Event sizing.

These declarations are implementation composition seams, not supported SDK API. The consumer fixtures and implementation-type sealing checks in `Scripts/verify-package.sh` passed for both SwiftPM and CocoaPods.

## Product and Runtime Inventory

- SwiftPM products and targets: unchanged.
- CocoaPods subspecs and source ownership: unchanged.
- Core and SDK third-party runtime dependencies: none added.
- Entitlements and privacy declarations: unchanged.
- Process lease, lifecycle observation, reconnection, persistence, Keychain, UI, and performance collection: absent from the active-pump diff.

Boundary evidence: `verify-boundaries.sh`, `verify-structure.sh`, the package consumer fixtures, process-lease multi-image validation, and the ownership/resource audit all passed.
