# Spec-to-Evidence Audit

## Demo owns one explicit SDK and Performance lifecycle

- The App factory creates one NearWire with the fixed enabled recovery policy and injects that instance into the model, monitor, and connection UI.
- The structured scene task forwards background, active, and inactive through the model and driver without starting an initial connection.
- The focused Demo test asserts all fixed policy values plus idle suspend/resume behavior.
- Existing manual Disconnect, Reset, teardown, and no-persistence boundaries were preserved and independently reviewed.

Evidence: production diff, focused Demo result, affected Demo suite, architecture review, and security/performance review.

## Demo validation uses public product boundaries

- The Demo test uses public NearWire state and configuration only; it does not emulate transport.
- The SDK regression proves an Event queued during suspension drains on the fresh route with the new session epoch.
- The Viewer regression uses the production composite journal, live memory window, selected Device scope, and Timeline.
- SwiftPM and CocoaPods consumer builds plus Simulator launch smoke passed.

Evidence: `implementation-validation.md`.

## Demo operation is documented for internal developers

- The runbook states Paused, Reconnecting with attempt number, Connected, and terminal Disconnected behavior.
- It states bounded retries, fresh TLS/session recovery, in-memory pairing intent, no continuous background execution, no process-termination recovery, and non-acknowledged Event delivery.

Evidence: `Demo/README.md` and both independent review rounds.

## Active Device selection follows exact-route reconnect replacement

- Migration requires a previously non-recent selected predecessor, no remaining non-recent snapshot for its UUID, and a different non-recent successor with the exact same logical route.
- Other selections are preserved; historical selections are not retargeted; stale missing selections retain the existing cleanup behavior.
- The selection is migrated before the bounded evaluator refresh, and existing rows are not cleared while evaluation is pending.
- The focused integration regression proves fresh-epoch Event visibility in Timeline and historical-selection independence. The full Viewer suite passed.

Evidence: production diff, focused Viewer regression, full Viewer suite, and clean correctness review.

## Environment limitation

The optional physical-device smoke was attempted but Xcode reported that the Wi-Fi-connected phone needed to be unlocked to recover from device preparation errors. This limitation is recorded without claiming the smoke passed. Deterministic lifecycle, transport replacement, and product Timeline behavior are covered by the passing regressions.

## Audit result

Every requirement and scenario in the active change has corresponding implementation, deterministic validation, documentation, or an explicitly permitted environment-limitation record. No unresolved finding or unverified completion claim remains.
