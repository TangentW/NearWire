# Viewer

This directory owns the native macOS Viewer application and its unit tests.

The user-visible application name is `NearWire`. The manually maintained Xcode project, target, and Swift module use `NearWireViewer` to avoid a module-name collision with the SDK product.

`NearWireViewer.xcodeproj` supports macOS 13 and Swift 5 language mode. It references the repository root as a local Swift package and links the internal `NearWireCore` product. It currently uses Apple frameworks only; any future Viewer-only package must remain attached to this Xcode project and must not be added to the root `Package.swift`.

Select the team's stable Apple Development identity before running the maintained app. Keep that signer across internal updates so the macOS login-Keychain identity remains accessible without prompts. Developer ID is the distribution alternative; ad-hoc signing is used only by isolated test and inspection commands.

Opening the single main window automatically prepares the persistent Viewer identities, creates an ephemeral pairing code, and publishes the mandatory-TLS peer-to-peer Bonjour listener. Closing the last window stops the runtime. The application does not install a menu-bar agent or daemon.

After admission, the Viewer owns up to 16 independent App sessions. It completes flow-policy negotiation, exchanges bounded bidirectional Events, retains requested policy and nicknames in bounded `UserDefaults` records, and presents per-device rate, queue, throughput, and drop telemetry. Peer-declared installation and Bundle identifiers remain unauthenticated hints.

The Viewer also records bounded local history through three serialized system-SQLite connections. Storage configuration and safe status are available in the main window. Local schema ownership, permissions, quota and retention semantics, gaps, recovery, query snapshots, and unencrypted JSON export disclosure are documented in [Viewer-Local-Store.md](../Documentation/Viewer-Local-Store.md).

The three-column Event Explorer, transient-versus-recorded semantics, source/device materialization, filtering, pause behavior, bounded renderers, causality inspection, recording operations, JSON export, and memory-only Viewer-to-App composer are documented in [Viewer-Event-Explorer.md](../Documentation/Viewer-Event-Explorer.md).

Identity lifecycle, pairing, listener replacement, admission limits, recovery, sandbox, privacy behavior, and the three-phase stable-signer XCTest command sequence are documented in [Viewer-Foundation.md](../Documentation/Viewer-Foundation.md).

Session ownership, logical correlation, policy negotiation, queue atomicity, receive backpressure, preferences, and the operational workspace are documented in [Viewer-MultiDevice-Flow-Control.md](../Documentation/Viewer-MultiDevice-Flow-Control.md).
