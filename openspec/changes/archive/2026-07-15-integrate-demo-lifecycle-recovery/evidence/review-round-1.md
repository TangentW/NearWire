# Independent Review Round 1

## Architecture and API

Clean. The reviewer confirmed the Demo applies the existing public lifecycle API to one shared NearWire instance, preserves explicit initial and manual disconnect authority, and adds no SDK-owned platform lifecycle or background mode.

## Correctness and testing

Two actionable findings:

1. High: a selected Viewer Device remained scoped to the predecessor connection UUID after exact-route reconnect. The replacement Event reached the low-level sink but could be hidden by the stale Timeline Device filter.
2. Medium: the Demo lifecycle regression used a default recovery-disabled NearWire instance and therefore did not prove the maintained App enabled the specified six-attempt, 500-millisecond-to-four-second policy.

Both were fixed. The Explorer now migrates only a previously non-recent selection to a different non-recent connection for the exact same logical route before evaluation. The Viewer regression now traverses the production journal, live memory window, selected Device scope, and Timeline. The Demo test constructs the maintained App configuration and asserts all policy values before lifecycle forwarding.

## Security, performance, and documentation

One actionable documentation finding: the runbook described recovery mechanics but omitted the observable Paused, Reconnecting, Connected, and terminal Disconnected progression required by the capability scenario. The runbook now states that progression and the explicit pairing requirement after permanent failure or retry exhaustion.
