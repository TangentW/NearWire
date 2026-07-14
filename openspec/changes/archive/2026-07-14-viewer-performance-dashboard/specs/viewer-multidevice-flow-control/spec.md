## MODIFIED Requirements

### Requirement: Device workspace exposes session control and composes with the Event Explorer

The Viewer sidebar SHALL list negotiating, active, disconnecting, and recently disconnected correlation rows with safe identity hints, nickname, state, and bounded warning indicators. A returning connection SHALL use the ordinary negotiating state; there SHALL be no separate reconnecting state. The workspace SHALL explicitly label App identity, installation alias, Bundle ID, nickname continuity, and recent-row presentation as unauthenticated and SHALL NOT imply that any one proves the returning App. A selected connected device SHALL show editable nickname, requested App uplink/downlink rates, separately labeled effective rates, queue count/bytes/oldest wait, throughput, Event counts, and drop totals. Invalid rate or nickname input SHALL be rejected locally with fixed safe guidance. Disconnected rows SHALL not permit rate mutation.

The workspace SHALL preserve the foundation pairing, approval, pause, and recovery controls and SHALL compose them with Events and Performance modes without creating a second session manager or protocol owner. Event content and decoded performance values SHALL appear only in the explicit Event timeline/inspector/composer or Performance dashboard surfaces; safe device rows, pending/recent rows, queue telemetry, errors, logs, preferences, and generic reflection SHALL remain content-free. Performance SHALL accept exactly one current or historical device session. V1 multi-device performance overlays remain deferred.

Controls and state SHALL have accessibility labels and deterministic presentation-model coverage.

#### Scenario: User selects an active device

- **WHEN** an active logical route is selected
- **THEN** its requested and effective rates are clearly distinguished and the same device may scope the Event timeline or Performance page
- **AND** its current queue and transfer telemetry remain available without exposing Event or decoded performance content in the device row

#### Scenario: Device disconnects while selected

- **WHEN** the selected session terminates
- **THEN** the row enters bounded recent-disconnect presentation or is removed after expiry
- **AND** rate mutation and new control admission are disabled without selecting an unrelated device
