# Design

## Root cause

Both broken paths attempt overlapping macOS presentations:

- Import sets the SwiftUI `fileImporter` binding from the action of a still-dismissing alert.
- Export calls modeless `NSSavePanel.begin` from inside an attached SwiftUI disclosure sheet.

In both cases the file panel can fail to become visible or can be ordered behind the active sheet.
The transfer services are not the failing boundary: their existing memory round-trip tests already
exercise JSON encoding, atomic writing, bounded parsing, and replacement.

## Presentation sequencing

The Devices region owns one window-scoped file-panel coordinator. A lightweight AppKit anchor keeps
a weak reference to the exact Viewer window without retaining it.

Import and export each use a SwiftUI disclosure sheet. Choosing a file does not open another
presentation immediately. Instead it:

1. records a bounded pending request;
2. dismisses the disclosure sheet;
3. waits for that sheet's `onDismiss` boundary;
4. opens `NSOpenPanel` or `NSSavePanel` with `beginSheetModal(for:)` on the anchored Viewer window.

Only one native panel is retained by the coordinator. Completion clears it before calling product
state. Window loss or panel cancellation returns `nil` through the same closed path.

The Viewer remains sandboxed. Its existing target-bound entitlement file declares
`com.apple.security.files.user-selected.read-write`, allowing Powerbox-selected import and export
URLs to be read or written without granting broad filesystem access.

## State behavior

- Import cancellation calls `cancelCurrentSessionImportSelection()` so the workspace returns from
  `selectingImport` to `idle`.
- A chosen import URL enters the existing security-scoped, bounded, atomic import path.
- Export cancellation leaves the prepared ticket in disclosure state and reopens that disclosure,
  allowing another destination attempt or explicit cancellation.
- A chosen export URL starts the existing atomic writer and reopens the export sheet to show
  progress and completion.
- Runtime teardown still cancels the active panel through the controller's existing destination
  cancellation closure.

## Validation

- Strict OpenSpec validation before implementation.
- Focused tests for disclosure-to-panel sequencing, cancellation, destination selection, and
  controller export state.
- A running-process assertion for the user-selected file read/write entitlement.
- Existing memory Session JSON round-trip, invalid-file, capacity, and cancellation tests.
- Viewer test target build and focused/full maintained test execution in proportion to this scope.
- Running Viewer verification of import cancellation, valid import, save-panel appearance, export,
  clear/replace behavior, and re-import of the exported file.
- Independent architecture/API, correctness/testing, and
  security/performance/documentation reviews followed by a fresh no-findings round.
