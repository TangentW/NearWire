## MODIFIED Requirements

### Requirement: Active Device selection follows exact-route reconnect replacement

The Event Explorer SHALL preserve an operator's active logical Device focus across newest-session replacement. When a selected predecessor was non-recent in the prior session snapshot and a different non-recent connection for the exact same `ViewerLogicalRoute` appears in the successor snapshot, the Explorer SHALL replace the predecessor connection UUID with the successor UUID before its next bounded Timeline evaluation. It SHALL preserve other selected Devices and SHALL NOT migrate a deliberately selected historical recent connection, a different installation, or a different application route.

The Devices strip SHALL present at most one non-imported Device row for each exact `ViewerLogicalRoute`, even while the memory Session retains Events and lifecycle metadata from predecessor connection UUIDs. That row SHALL retain a stable process-local presentation identity across reconnect replacement and SHALL target the newest current connection when one exists, otherwise the most recently ended retained connection. Different logical routes and imported Devices SHALL remain distinct. Coalescing presentation SHALL NOT merge connection-scoped Event ordering, transport state, Performance samples, control capability, or wire session identity.

The selection migration SHALL use the existing in-memory selection refresh path and SHALL NOT clear existing rows while the successor evaluation is pending, create persistence, or treat the predecessor's Events as belonging to the successor session.

#### Scenario: Selected App reconnects with a fresh session

- **WHEN** an actively selected App connection is replaced by a fresh connection for the exact same logical route
- **THEN** the selected Device scope moves from the ended predecessor connection UUID to the fresh connection UUID before filtering the next memory snapshot
- **AND** a fresh-epoch Event admitted through the replacement session becomes visible in the Timeline without requiring All Devices or a manual Device reselection

#### Scenario: The same App reconnects repeatedly

- **WHEN** the memory Session retains predecessor connections and a newest connection exists for the exact same logical route
- **THEN** the Devices strip shows one stable Device row for that route
- **AND** the row targets the newest current connection instead of adding one card per reconnect

#### Scenario: Historical or different route remains independent

- **WHEN** a selected connection was already recent, or a new connection belongs to a different installation or application identifier
- **THEN** the Explorer does not retarget that selection
- **AND** distinct session and route identities remain independently filterable
- **AND** different logical routes and imported Device rows remain separate in the Devices strip
