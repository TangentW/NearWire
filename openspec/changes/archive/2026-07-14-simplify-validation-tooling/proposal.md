## Why

NearWire duplicates normal Swift, Xcode, and CocoaPods verification with a large custom `Scripts`
tree. Much of that tree tests its own validators or performs source-text assertions that overlap
the maintained unit and integration suites. This makes routine development and release checks
harder to understand without improving product behavior.

## What Changes

- Remove the custom validation, evidence-capture, fixture, and validator-test scripts, plus
  script-only consumer and process-loader fixtures that otherwise become dead files.
- Use direct `swift test`, `xcodebuild`, and `pod lib lint` commands for maintained verification.
- Remove repository documentation and canonical structure requirements that depend on `Scripts`.
- Keep historical archived evidence unchanged.
- Use a focused self-review for this low-risk tooling cleanup, as explicitly requested by the
  repository owner.

## Capabilities

### Modified Capabilities

- `repository-structure`: Removes `Scripts` as an authoritative repository root and makes standard
  toolchain commands the maintained verification entry points.

## Impact

- Deletes only validation tooling and its private fixtures; no Core, SDK, Viewer, Demo, or wire
  behavior changes.
- Developers run standard toolchain commands directly instead of a repository-specific wrapper.
- The change does not alter package products, pod subspecs, application targets, or runtime code.
