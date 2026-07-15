## MODIFIED Requirements

### Requirement: Device workspace exposes session control and composes with the Event Explorer

The Viewer Devices strip SHALL list negotiating, active, disconnecting, and recently disconnected correlation rows with safe identity hints, nickname, state, and bounded warning indicators. A returning connection SHALL use the ordinary negotiating state; there SHALL be no separate reconnecting state. The workspace SHALL explicitly label App identity, installation alias, Bundle ID, nickname continuity, and recent-row presentation as unauthenticated and SHALL NOT imply that any one proves the returning App. A selected connected Device SHALL expose the existing bounded settings and telemetry without Event or decoded Performance content in the row. Invalid rate or nickname input SHALL be rejected locally with fixed safe guidance. Disconnected rows SHALL not permit rate mutation.

The workspace SHALL preserve pairing, approval, pause, and recovery controls and SHALL compose one main Event window with one singleton Performance window without creating a second session manager, Store owner, listener, or protocol owner. Event content and decoded Performance values SHALL appear only in Timeline/Inspector/composer or Performance dashboard surfaces. Events MAY scope up to 16 current-Session Devices; Performance SHALL own one independent exact Device choice. V1 multi-Device Performance overlays remain deferred.

Controls and state SHALL have accessibility labels and deterministic presentation-model coverage.

#### Scenario: User selects an active Event Device

- **WHEN** an active logical route is selected in the main Device strip
- **THEN** its settings and telemetry target are explicit and it may scope the Event Timeline
- **AND** a valid existing Performance Device choice is not silently retargeted

#### Scenario: User selects a Performance Device

- **WHEN** the Performance window chooses one exact available Device
- **THEN** only the bounded Performance projection target changes
- **AND** main Event Device scope, selected Event, Inspector, and Device-details target remain unchanged

#### Scenario: Device disconnects while selected

- **WHEN** a selected session terminates
- **THEN** its row enters bounded recent-disconnect presentation or is removed after expiry
- **AND** invalid Performance selection uses only the documented exact fallback or is cleared without selecting an unrelated Device
