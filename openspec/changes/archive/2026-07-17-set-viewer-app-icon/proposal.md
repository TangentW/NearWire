# Change: Set the Viewer application icon

## Why

The macOS Viewer currently has no configured application icon. The supplied NearWire artwork should
identify the Viewer consistently in Finder, the Dock, and system application surfaces.

## What Changes

- Add one macOS AppIcon asset set derived from the supplied square PNG.
- Configure the Viewer target to compile and use the `AppIcon` asset.
- Leave SDK, Demo, runtime behavior, signing, and existing local project scheme changes untouched.

## Scope

This change affects only Viewer application resources and target asset-catalog configuration.
