# viewer-event-explorer-control Delta

## ADDED Requirements

### Requirement: Active Device selection follows exact-route reconnect replacement

The Event Explorer SHALL preserve an operator's active logical Device focus across newest-session replacement. When a selected predecessor was non-recent in the prior session snapshot and a different non-recent connection for the exact same `ViewerLogicalRoute` appears in the successor snapshot, the Explorer SHALL replace the predecessor connection UUID with the successor UUID before its next bounded Timeline evaluation. It SHALL preserve other selected Devices and SHALL NOT migrate a deliberately selected historical recent connection, a different installation, or a different application route.

The selection migration SHALL use the existing in-memory selection refresh path and SHALL NOT clear existing rows while the successor evaluation is pending, create persistence, or treat the predecessor's Events as belonging to the successor session.

#### Scenario: Selected App reconnects with a fresh session

- **WHEN** an actively selected App connection is replaced by a fresh connection for the exact same logical route
- **THEN** the selected Device scope moves from the ended predecessor connection UUID to the fresh connection UUID before filtering the next memory snapshot
- **AND** a fresh-epoch Event admitted through the replacement session becomes visible in the Timeline without requiring All Devices or a manual Device reselection

#### Scenario: Historical or different route remains independent

- **WHEN** a selected connection was already recent, or a new connection belongs to a different installation or application identifier
- **THEN** the Explorer does not retarget that selection
- **AND** distinct session and route identities remain independently filterable
