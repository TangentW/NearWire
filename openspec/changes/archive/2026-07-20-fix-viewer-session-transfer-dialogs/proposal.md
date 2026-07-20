# Change: Fix Viewer Session Transfer Dialogs

## Why

The Viewer currently requests an import picker directly from an alert action and requests an
`NSSavePanel` while the export disclosure sheet is still attached. macOS does not reliably present
a second file dialog during an existing sheet transition, so the operator can click the import or
export destination action and observe no visible response.

## What Changes

- Sequence import and export disclosures separately from their native file panels.
- Present each open/save panel as a sheet of the originating Viewer window only after the disclosure
  sheet has fully dismissed.
- Preserve the prepared immutable export while the destination is selected.
- Restore truthful presentation after file-panel cancellation and keep import cancellation from
  leaving the workspace in a selecting state.
- Declare the App Sandbox user-selected file read/write entitlement required by the native import
  and export panels.
- Add focused controller, presentation-sequencing, and memory transfer coverage, then exercise a
  complete import → export → import round trip in the running Viewer.

## Impact

- Only the macOS Viewer session-transfer presentation and its tests are affected.
- The JSON schema, memory limits, disclosure content, import validation, atomic file replacement,
  SDK, Core, and Demo remain unchanged.
