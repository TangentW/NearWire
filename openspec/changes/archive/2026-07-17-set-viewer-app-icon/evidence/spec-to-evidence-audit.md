# Spec-to-evidence audit

Date: 2026-07-18

| Requirement | Evidence |
|---|---|
| Viewer compiles one `AppIcon` asset | Viewer build passed and produced `AppIcon.icns` plus `Assets.car`. |
| Debug and Release select `AppIcon` | Both Viewer target build configurations contain `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`. |
| Every standard macOS slot exists | `Contents.json` declares ten 1x/2x slots and `sips` verified every exact pixel size. |
| Artwork is derived without compositional change | Generated representations are direct square downsampling of the supplied opaque PNG; compiled icon was visually inspected. |
| SDK and Demo are unaffected | Project diff attaches the catalog only to the Viewer application resources phase. |

Validation is recorded in `implementation-validation.md`. Independent review reported no findings.
