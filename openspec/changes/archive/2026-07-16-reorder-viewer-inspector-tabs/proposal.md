# Change: Reorder Viewer inspector tabs

## Why

The Event Inspector currently places Metadata first and Pretty JSON later, while formatted Event
content is the primary inspection view. The control should present Pretty at the leading edge and
Metadata at the trailing edge.

## What Changes

- Place Pretty first in the Event Inspector view selector.
- Place Metadata last while preserving Raw and Preview between them.
- Keep the existing inspector behavior and selected-tab state unchanged.

## Impact

The Event Inspector selector reads from left to right as Pretty, Raw, Preview, and Metadata.
