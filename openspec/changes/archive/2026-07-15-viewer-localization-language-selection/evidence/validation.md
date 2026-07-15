# Validation Evidence

Validation date: 2026-07-15 (Asia/Shanghai)

## Focused localization and layout tests

Command:

```sh
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/nearwire-localization-focused-review CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -only-testing:NearWireViewerTests/ViewerLocalizationTests -only-testing:NearWireViewerTests/ViewerFoundationTests/testControlComposerScalesToCompactWidthWithDeterministicEditorFocusOrder -only-testing:NearWireViewerTests/ViewerFoundationTests/testFilterSheetRendersExpandedControlsWithinMinimumBounds
```

Result: PASS. The final focused run covered language preference, canonical invalid-value recovery, every-Chinese-locale resolution, resource parity and placeholders, locale-aware formatting, system notification deduplication, source boundaries, and English/Simplified Chinese compact layouts. A final isolated source-boundary rerun also passed after simplifying its regular expressions.

## Full Viewer regression suite

Command:

```sh
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/nearwire-localization-full-tests CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

Result: PASS. `465` tests executed, `2` skipped, `0` failures. Result bundle:

`/tmp/nearwire-localization-full-tests/Logs/Test/Test-NearWireViewer-2026.07.15_20-01-43-+0800.xcresult`

An earlier full-suite run exposed two host-language-dependent accessibility assertions. Those existing layout tests were made deterministic with an explicit English environment and extended with Simplified Chinese layout coverage before the clean final run.

## Root Swift package regression suite

Command:

```sh
env SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-spm-module-cache CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-module-cache swift test
```

Result: PASS outside the enclosing filesystem sandbox because SwiftPM's own `sandbox-exec` cannot nest inside it. `546` tests executed with `0` failures.

## Viewer Release build

Command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Release -destination 'platform=macOS' -derivedDataPath /tmp/nearwire-localization-release CODE_SIGNING_ALLOWED=NO build
```

Result: PASS. Both macOS architectures compiled, the String Catalog compiled, and the application bundle validated.

## Demo regression build

Command:

```sh
xcodebuild -project Demo/NearWireDemo.xcodeproj -scheme NearWireDemo -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/nearwire-localization-demo CODE_SIGNING_ALLOWED=NO build
```

Result: PASS. The Viewer-only localization change did not alter Demo package integration.

## OpenSpec and patch hygiene

Commands:

```sh
OPENSPEC_TELEMETRY=0 openspec validate viewer-localization-language-selection --strict
git diff --check
```

Result: PASS both before review and after final evidence completion.

## Signing boundary

Normal local signed tests initially encountered the pre-existing app/test signer mismatch. Validation therefore used one explicit ad-hoc identity for both targets. No signing setting is part of this change. Existing local Demo and Viewer project/scheme signing or formatting changes remain outside the staged feature diff.
