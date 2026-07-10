# Viewer

This directory owns the native macOS Viewer application.

The user-visible application name is `NearWire`. The manually maintained Xcode project, target, and Swift module use `NearWireViewer` to avoid a module-name collision with the SDK product.

The first Viewer implementation change will create `NearWireViewer.xcodeproj`, application sources, tests, configuration, and Viewer-only Swift Package dependencies. Viewer dependencies must not be added to the root `Package.swift`.
