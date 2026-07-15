## MODIFIED Requirements

### Requirement: Projection work makes progress, stays fresh, and handles Store availability

Current-Session Performance projection SHALL consume only the bounded in-memory Session. Initial load, explicit scope replacement, empty state, pause/resume, and failure SHALL publish their visible states. When a complete publication already exists, refresh start and progress SHALL remain internal and SHALL NOT publish an intermediate loading presentation, replace the notice branch, reset scroll position, or recreate chart containers. Applying a valid completed successor SHALL publish exactly once; a discarded or equivalent successor SHALL publish no visible change.

Projection and decode work SHALL remain off the MainActor under the existing bounded paging, cancellation, and memory-budget rules. Database availability SHALL NOT be a current-Session Performance state. Ranges that begin before the retained memory window SHALL show truthful memory-window coverage without synthesizing missing values.

#### Scenario: New performance Event refreshes an existing dashboard

- **WHEN** cards and charts are already visible and a new snapshot Event arrives
- **THEN** the prior complete dashboard remains continuously visible during projection
- **AND** one completed successor updates the affected values without a temporary loading notice or implicit animation

#### Scenario: Requested range predates memory retention

- **WHEN** the selected range begins before the oldest retained Event
- **THEN** Viewer marks the leading range as unavailable memory-window coverage
- **AND** it does not query a database or interpolate missing samples

### Requirement: Performance UI is accessible, privacy-aware, and fully cleared

The native singleton macOS Performance window SHALL use an accessible exact-Device picker, scalable current cards, a fixed 16-key availability section, six bounded system Charts views, fixed ranges, one synchronized pointer/keyboard crosshair, aggregate tooltip, representative raw action, Show Viewer action, and deterministic runtime/device/empty/loading/memory-window/error guidance. State SHALL not rely on color. Accessibility SHALL combine metric, unit, Viewer time, statistics, discontinuity, and availability within the 64-summary-per-chart cap.

Completed cards and charts SHALL retain stable group and metric identity across ordinary Event refresh. Data refresh SHALL disable implicit animation without disabling hover, drag, keyboard crosshair, scrolling, or range controls. Received values SHALL have no copy, cut, drag, share, clipboard-export, preference, restoration, recent-row, log, analytics, database, or content-bearing reflection sink. Closing Performance or ending the runtime SHALL cancel work and clear all received metric content.

#### Scenario: Dashboard refreshes at normal sampling cadence

- **WHEN** built-in performance Events arrive repeatedly
- **THEN** card and chart containers keep stable identity and interaction state
- **AND** completed values update without whole-window flashing

#### Scenario: Performance window closes

- **WHEN** the operator closes Performance
- **THEN** received metric values, buckets, tooltip, cache, locators, and delivery state are cleared
- **AND** no Performance content is persisted locally
