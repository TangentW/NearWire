## MODIFIED Requirements

### Requirement: Pairing and Bonjour publication are exact and ephemeral

Each listener generation SHALL generate one four-character pairing code from the canonical
31-character alphabet using `SecRandomCopyBytes` with unbiased rejection sampling. The code SHALL
exist only in bounded runtime/UI state and optional user-initiated clipboard content. It SHALL NOT
be persisted or emitted to logs, errors, analytics, Keychain, or session data.

After identity readiness, Viewer SHALL create one mandatory-TLS, peer-to-peer-enabled listener
advertising the exact `NearWire-<code>` instance under `_nearwire._tcp` in the local domain. TXT
data SHALL contain only one valid `vid` derived from the stable Viewer installation ID. The code
SHALL become usable/presented as listening only after listener readiness and exact-name service
registration. Registration rename or collision SHALL cancel the misleading publication and retry
with a fresh code under a finite bound; exhaustion SHALL fail safely.

#### Scenario: Listener becomes available

- **WHEN** identities, listener readiness, and exact service registration all succeed
- **THEN** the UI presents the canonical pairing code with Copy and Refresh actions
- **AND** discovery publishes only the expected instance, type, domain, and `vid`

#### Scenario: Bonjour auto-renames the service

- **WHEN** Network.framework registers a different instance name
- **THEN** Viewer does not present the old code as usable
- **AND** it cancels that listener and performs only the bounded fresh-code retry policy

#### Scenario: User refreshes the code

- **WHEN** a usable listener receives Refresh Pairing Code
- **THEN** a replacement publication uses a fresh code and the same persistent identities
- **AND** already handed-off connections are not cancelled by ordinary refresh

### Requirement: Foundation UI is truthful and recovery-oriented

The main window SHALL show a compact pairing label, a visually prominent 36-point monospaced
pairing code, listener status, Copy, Refresh, Pause/Resume, the approval setting, pending approval
actions, fixed identity/listener recovery actions, one bounded Devices strip, memory-Session
import/export actions, and Timeline/Inspector/Composer visibility controls. Pairing status and its
connection actions SHALL occupy the leading side of one header row, while approval SHALL occupy the
trailing side of that row. It SHALL NOT present a Sources or recorded-session sidebar,
local-database settings, database status, cleanup, retry, capacity, retention, durable-recording
state, or persistent explanatory transport/discovery captions below the pairing status.

All controls SHALL expose accessibility labels, help, keyboard focus, and disabled states derived
from the single application model. User-visible and diagnostic errors SHALL use closed safe
categories and SHALL NOT include pairing code, identity material, endpoint/interface descriptions,
wire bytes, App content, imported Event content, or arbitrary system error text.

#### Scenario: Listener is ready

- **WHEN** the exact service is registered
- **THEN** the compact pairing label, 36-point code, listener state, adjacent connection actions,
  and trailing approval setting are visible without clipping
- **AND** Device, memory-Session, and available workspace actions use truthful enabled states
- **AND** no database lifecycle, storage setting, or persistent explanatory caption is presented
