## MODIFIED Requirements

### Requirement: Viewer application metadata and privacy match local discovery

Viewer SHALL enable App Sandbox with both the network-server and network-client entitlements
required by its Network.framework listener and accepted-connection path. It SHALL NOT request
multicast, Keychain-sharing, application-group, or background-service entitlements. The built
Info.plist SHALL list `_nearwire._tcp` in `NSBonjourServices` and SHALL contain the English
local-network usage description `NearWire advertises a local service so your iPhone apps can
connect to this Mac.` Local-network denial SHALL produce a fixed recoverable failure and no
alternate or plaintext listener.

Viewer SHALL package its own valid `PrivacyInfo.xcprivacy` declaring linked Device ID for App
functionality and tracking false because it publishes stable `vid` and sends its installation ID
in Viewer Hello. It SHALL omit tracking domains and SHALL declare
`NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1` for the app-local approval
preference while omitting unused Required Reason API categories. Build evidence SHALL inspect the
final Info.plist, signed entitlements, and packaged privacy resource.

#### Scenario: Built Viewer metadata is audited

- **WHEN** the committed Viewer application is built and signed for macOS
- **THEN** its product contains the local-network description, NearWire Bonjour service, exact
  sandbox server and client entitlements, and Viewer privacy manifest
- **AND** no multicast, Keychain-sharing, app-group, tracking, or unused Required Reason
  declaration is present beyond the required app-local UserDefaults reason

#### Scenario: Sandboxed Viewer accepts an iPhone flow

- **WHEN** a discovered iPhone App opens a connection to the sandboxed Viewer listener
- **THEN** macOS permits the accepted Network.framework flow to reach the Viewer
- **AND** the connection proceeds through the existing mandatory TLS and admission path

#### Scenario: Local-network access is unavailable

- **WHEN** listener startup reports local-network denial or unavailability
- **THEN** Viewer shows fixed recovery guidance and publishes no fallback service
