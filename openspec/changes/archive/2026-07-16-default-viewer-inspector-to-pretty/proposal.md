# Change: Default Viewer inspector to Pretty

## Why

Formatted Event content is the primary inspection view, but a newly created Viewer workspace still
selects Metadata by default.

## What Changes

- Make Pretty the initial Event Inspector selection.
- Preserve subsequent operator tab selection through the existing SwiftUI state.

## Impact

Opening an Event Inspector workspace starts on Pretty instead of Metadata.
