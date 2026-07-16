# Change: Reuse one Device row across reconnects

## Why

The runtime correctly replaces current ownership for the same logical route, but the Event
Explorer builds Device cards from every connection retained by the memory Session. Repeated SDK
reconnects therefore leave multiple cards with the same App name and installation alias even
though only one logical App/device route is current.

## What Changes

- Group non-imported Device presentation by the existing logical route: installation identity plus
  application identifier.
- Prefer the current runtime connection for that route; otherwise show the most recently ended
  retained connection.
- Give the logical row a stable process-local presentation identity so SwiftUI reuses the card
  across connection UUID replacement.
- Keep imported Devices distinct and preserve connection-scoped Event, Performance, transport, and
  control semantics.

## Impact

- Reconnecting the same App/device keeps one Device card instead of adding another.
- The card points to the newest current connection and continues to support selection and details.
- Different installations or application identifiers remain separate Devices.
