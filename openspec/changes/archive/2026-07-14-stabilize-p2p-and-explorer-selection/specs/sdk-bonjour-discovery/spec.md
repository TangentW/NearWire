## MODIFIED Requirements

### Requirement: Discovery lifecycle is explicit and race-safe

Construction SHALL start no browser, task, timer, or permission request. One explicit `run()` SHALL transition to searching before invoking the driver and SHALL complete exactly once with one internal `DiscoveredViewer` or one safe error. A second run in any non-idle state SHALL fail without replacing the first waiter. Cancel before run SHALL become terminal without touching the driver; cancellation after driver start SHALL cancel it at most once. An exact match SHALL complete endpoint selection without cancelling the peer-to-peer-enabled browser; it SHALL erase pairing-derived selection state and detach state and result callback processing before returning the match. The silent started browser lifetime SHALL remain retained by the selected secure session until the first setup failure, cancellation, or active-session terminal transition releases it exactly once. Ordinary waiting SHALL recover to searching only on ready. Recognized policy denial, start failure, browser failure, ambiguity, and unsolicited browser cancellation SHALL have the terminal behavior defined by the design state table. Ordered bounded callback ingress SHALL prevent late, duplicated, synchronous, or reentrant driver events from reviving terminal discovery or producing a second completion.

#### Scenario: Cancel races with exact match

- **WHEN** cancellation and an exact-match callback race
- **THEN** exactly one terminal outcome wins
- **AND** the browser is cancelled at most once

#### Scenario: Exact match transfers browser lifetime

- **WHEN** one exact Viewer match wins and secure session setup begins
- **THEN** endpoint selection completes without cancelling the started browser
- **AND** pairing-derived selection state and all browser callbacks are released
- **AND** later Bonjour result changes perform no conversion or matching work
- **AND** the secure session retains the discovery operation while that session may use peer-to-peer Wi-Fi

#### Scenario: Selected session terminates

- **WHEN** a selected session fails setup, is cancelled, or reaches its first active terminal transition
- **THEN** its retained browser is cancelled exactly once
- **AND** no discovery callback can produce another match or reconnect

#### Scenario: Late callback

- **WHEN** a result, waiting, or failure callback arrives after a terminal outcome
- **THEN** it is ignored and retains no endpoint

#### Scenario: Waiting recovers

- **WHEN** ordinary waiting is followed by ready
- **THEN** discovery returns to searching and requires a later complete snapshot before matching

#### Scenario: Policy denial while waiting

- **WHEN** waiting reports the recognized local-network policy-denied error
- **THEN** discovery fails terminally, cancels the driver once, and requires a new explicitly created discovery after Settings change

#### Scenario: Reentrant callback during start

- **WHEN** the injected driver invokes a callback synchronously from start
- **THEN** the callback observes initialized searching state through bounded ingress
- **AND** the one-shot result still completes at most once
