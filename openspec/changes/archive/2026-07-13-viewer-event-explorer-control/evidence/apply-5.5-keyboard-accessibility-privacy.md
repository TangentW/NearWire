# Task 5.5 Keyboard, Accessibility, and Privacy Evidence

Date: 2026-07-13

## Implemented contract

- `ViewerOperatorTextView` is one native AppKit editing surface used by the composer, primary search,
  filter sheet, and recording metadata/annotation editor. Its `NSTextViewDelegate` receives the
  exact UTF-16 replacement range and replacement text, calls the owning incrementally accounted
  model synchronously, and permits AppKit storage only after that model accepts the edit. This
  applies to typing, ordinary user-invoked copy/cut/paste, deletion, undo, and input-method edits.
- Single-line controls reject newline insertion and submit through the native command path;
  multiline JSON, note, and annotation controls admit newlines within the same byte/scalar bounds.
  Smart quotes, dash substitution, spelling replacement, rich text, graphic import, and link
  detection are disabled so stored operator text remains deterministic.
- The AppKit text system is explicitly owned as `NSTextStorage -> NSLayoutManager ->
  NSTextContainer`. The SwiftUI representable avoids programmatic synchronization while a native
  edit callback is active, preserves a legal insertion point on external updates, and clears text,
  callbacks, and accessibility content when dismantled. Text view descriptions/debug descriptions
  and mirrors are redacted.
- `ViewerReceivedEventTextView` renders Raw and Pretty received/stored Event content as a dedicated
  display-only surface. It is noneditable, nonselectable, cannot become first responder, has no
  menu, unregisters drag types, validates no responder command, performs no pasteboard access, and
  clears content when dismantled. Other inspector labels remain ordinary nonselectable SwiftUI
  text; no copy, cut, paste, drag, share, or clipboard-export action was added.
- The existing separately disclosed JSON file export remains unchanged and available through its
  save-panel path. No destination, clipboard value, custom history, or restoration value is
  retained.
- Source, device, target, timeline, result, and state rows combine deterministic English labels
  with selected/recording/disposition/gap/drop/conflict/terminal state where applicable. State is
  always expressed by text and/or a symbol, never color alone. Operator controls include explicit
  labels and hints; source/timeline/inspector/composer sections remain keyboard reachable through
  native focus behavior and explicit SwiftUI focus sections. Composer submission has Command-Return
  and filter application has Command-Return.
- `ViewThatFits` preserves the three-column composer at ordinary width and selects one vertically
  scrollable target/input/action layout when width is constrained. The compact fixture renders at
  620 points, exposes exactly the Event type, JSON content, and TTL native editors in deterministic
  focus order, and keeps all three able to become first responder.
- No Event content, type, target capability, validation value, or clipboard value is written to
  logs, preferences, recent rows, restoration, or safe device/status presentation.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests/testNativeTextControlsBoundExactEditsAndDisableInspectorClipboardSurfaces -only-testing:NearWireViewerTests/ViewerFoundationTests/testControlComposerScalesToCompactWidthWithDeterministicEditorFocusOrder -only-testing:NearWireViewerTests/ViewerFoundationTests/testRootViewComposesWithoutStartingRuntime -only-testing:NearWireViewerTests/ViewerFoundationTests/testRunningRootComposesEventExplorerAndRuntimeCleanupSealsIt -only-testing:NearWireViewerTests/ViewerFlowControlTests/testControlComposerUsesOpaqueTargetsCancelsReplacedAttemptAndReportsLocalAdmission
```

Result: `TEST SUCCEEDED`; 5 tests executed, 0 failures.

The focused tests exercise real `NSTextView` delegate range edits with multibyte content, exact
pre-storage rejection, single/multiline command behavior, availability of standard operator editor
copy/cut/paste selectors, the closed inspector command/selection/menu/drag boundary, redacted
reflection and dismantle clearing, compact layout/focus order, root lifecycle cleanup, and composer
admission regression.

## Test-driven remediation

The first privacy-control test correctly failed because the initial subclass initializer passed a
nil text container and therefore did not retain a functioning AppKit text-storage stack. The test
observed the bounded model value `éab🙂` while the control remained empty. The implementation now
constructs and retains the complete text system for both operator and received-content controls. A
fresh single-test run and the five-test final command above both passed. No assertion was weakened.

## Complete Viewer validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 224 tests executed, 2 skipped, 0 failures.

One skip is the explicit machine-local Application Support audit marker gate. The
configured-signing application entitlement assertion is the other skip and remains intentionally
deferred to the user-approved Goal-level release-hardening verification. This unsigned validation
does not claim release-signing evidence.

## Static and specification validation

Commands and results:

```text
xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
# exit 0, no output

git diff --check
# exit 0, no output

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
# Change 'viewer-event-explorer-control' is valid

rg -n "textSelection|contextMenu|onDrag|draggable|ShareLink|NSSharing|NSPasteboard|Pasteboard|UserDefaults|print\(|NSLog|Logger" Viewer/NearWireViewer/UI/ViewerTextControls.swift Viewer/NearWireViewer/UI/ViewerEventExplorerView.swift Viewer/NearWireViewer/UI/ViewerControlComposerView.swift Viewer/NearWireViewer/Application/ViewerControlComposerController.swift Viewer/NearWireViewer/Application/ViewerEventExplorerController.swift
# exit 1, no matches: the scoped Event UI/controller sources add no selection, clipboard,
# drag/share, preferences, or logging path.
```
