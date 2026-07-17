# Implementation validation

Date: 2026-07-18

## Source asset

```text
/Users/tangent/Downloads/icon.png
PNG, 1254 x 1254, RGB, opaque
```

The source was downsampled without cropping or compositional changes into the ten standard macOS
AppIcon slots. `sips` reported the expected pixel dimensions:

| Slot | Pixel dimensions |
|---|---:|
| 16 pt, 1x | 16 x 16 |
| 16 pt, 2x | 32 x 32 |
| 32 pt, 1x | 32 x 32 |
| 32 pt, 2x | 64 x 64 |
| 128 pt, 1x | 128 x 128 |
| 128 pt, 2x | 256 x 256 |
| 256 pt, 1x | 256 x 256 |
| 256 pt, 2x | 512 x 512 |
| 512 pt, 1x | 512 x 512 |
| 512 pt, 2x | 1024 x 1024 |

Both asset-catalog JSON files pass `jq empty`, and the Xcode project passes `plutil -lint`.

## Viewer build

Command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/NearWireViewerIconBuild \
  CODE_SIGNING_ALLOWED=NO build -quiet
```

Result: passed, exit 0.

The built application contained:

```text
NearWire.app/Contents/Resources/AppIcon.icns
NearWire.app/Contents/Resources/Assets.car
```

The processed Info.plist contained:

```text
CFBundleIconFile = AppIcon
CFBundleIconName = AppIcon
```

Converting the compiled `AppIcon.icns` back to PNG produced the expected NearWire artwork.

## Scope checks

`git diff --check` passed. The asset catalog is referenced only by the Viewer application target.
Existing local Demo project, Demo scheme, and Viewer scheme changes were not modified.
