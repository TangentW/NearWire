# Design

The source artwork is a 1,254-by-1,254 opaque PNG. Viewer will retain its composition and color,
downsampling it to the standard macOS icon representations: 16, 32, 64, 128, 256, 512, and 1,024
pixels. Shared pixel sizes used by different scale slots may use separate conventional filenames.

The generated files live in
`Viewer/NearWireViewer/Resources/Assets.xcassets/AppIcon.appiconset`. The asset catalog is added to
the Viewer resources build phase, and both Debug and Release configurations set
`ASSETCATALOG_COMPILER_APPICON_NAME` to `AppIcon`.

Validation builds the unsigned Viewer target, inspects the compiled product for `AppIcon.icns`, and
checks every source representation's exact pixel dimensions.
