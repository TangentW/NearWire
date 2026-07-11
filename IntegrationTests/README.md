# Integration Tests

This directory owns behavior that crosses package targets or device roles.

The first checked-in suite is `Fixtures/Protocol/v1`. It contains canonical JSON and complete framed hexadecimal values for representative hello, error, event, and event-batch messages. `NearWireTransportTests` verifies these values byte for byte and decodes them so accidental protocol drift fails locally and in CI.

Future suites include package-manager integration, iOS-to-macOS end-to-end sessions, reconnection, multi-device isolation, and release compatibility checks.

Unit tests remain next to their owning Core, SDK, or Viewer modules.
