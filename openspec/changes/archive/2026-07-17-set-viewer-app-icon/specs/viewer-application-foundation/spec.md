## ADDED Requirements

### Requirement: Viewer packages the NearWire application icon

The maintained macOS Viewer target SHALL compile one `AppIcon` asset catalog derived from the
repository's NearWire icon artwork. Debug and Release SHALL select that asset as the application
icon. The asset SHALL provide every standard macOS 16-, 32-, 128-, 256-, and 512-point slot at 1x
and 2x scale without changing the artwork's composition or introducing an SDK or Demo resource.

#### Scenario: Viewer is built

- **WHEN** the maintained Viewer target is built for macOS
- **THEN** the application bundle contains the compiled NearWire application icon
- **AND** Finder, Dock, and system application surfaces can resolve it from the bundle metadata
