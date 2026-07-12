# Viewer

This directory owns the native macOS Viewer application and its unit tests.

The user-visible application name is `NearWire`. The manually maintained Xcode project, target, and Swift module use `NearWireViewer` to avoid a module-name collision with the SDK product.

`NearWireViewer.xcodeproj` supports macOS 13 and Swift 5 language mode. It references the repository root as a local Swift package and links the internal `NearWireCore` product. It currently uses Apple frameworks only; any future Viewer-only package must remain attached to this Xcode project and must not be added to the root `Package.swift`.

Select the team's stable Apple Development identity before running the maintained app. Keep that signer across internal updates so the macOS login-Keychain identity remains accessible without prompts. Developer ID is the distribution alternative; ad-hoc signing is used only by isolated test and inspection commands.

Opening the single main window automatically prepares the persistent Viewer identities, creates an ephemeral pairing code, and publishes the mandatory-TLS peer-to-peer Bonjour listener. Closing the last window stops the runtime. The application does not install a menu-bar agent or daemon.

Identity lifecycle, pairing, listener replacement, admission limits, recovery, sandbox, privacy behavior, and the three-phase stable-signer XCTest command sequence are documented in [Viewer-Foundation.md](../Documentation/Viewer-Foundation.md).
