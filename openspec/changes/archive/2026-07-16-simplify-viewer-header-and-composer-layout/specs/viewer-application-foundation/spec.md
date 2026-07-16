## MODIFIED Requirements

### Requirement: Foundation UI is truthful and recovery-oriented

The main window SHALL show a compact pairing label, a visually prominent pairing code, listener status, Copy, Refresh, Pause/Resume, the approval setting, pending approval actions, fixed identity/listener recovery actions, one bounded Devices strip, memory-Session import/export actions, and Timeline/Inspector/Composer visibility controls. Pairing status and its connection actions SHALL occupy the leading side of one header row, while approval SHALL occupy the trailing side of that row. It SHALL NOT present a Sources or recorded-session sidebar, local-database settings, database status, cleanup, retry, capacity, retention, durable-recording state, or persistent explanatory transport/discovery captions below the pairing status.

All controls SHALL expose accessibility labels, help, keyboard focus, and disabled states derived from the single application model. User-visible and diagnostic errors SHALL use closed safe categories and SHALL NOT include pairing code, identity material, endpoint/interface descriptions, wire bytes, App content, imported Event content, or arbitrary system error text.

#### Scenario: Listener is ready

- **WHEN** the exact service is registered
- **THEN** the compact pairing label, prominent code, listener state, adjacent connection actions, and trailing approval setting are visible without clipping
- **AND** Device, memory-Session, and available workspace actions use truthful enabled states
- **AND** no database lifecycle, storage setting, or persistent explanatory caption is presented
