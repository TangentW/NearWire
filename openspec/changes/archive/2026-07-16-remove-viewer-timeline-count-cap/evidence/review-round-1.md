# Review Round 1

## Architecture and API

No actionable findings. The reviewer confirmed that the 1,024-slot defensive capacity represents every Event set valid under the 32 MiB budget and 32 KiB minimum accounting reserve, and that retention, import, evaluation, replacement, and Timeline publication remain aligned.

## Correctness and testing

One medium finding: pending disposition and conflict-key dictionaries were bounded to the 1,024 retained slots while authority can additionally own 64 accepted ingress keys. With a blocked projection executor, metadata for those ingress keys could be lost before their Events entered the retained window.

Resolution: production code now uses one `maximumPendingEventKeys` bound equal to the byte-derived retained slots plus the fixed ingress slots for authority, dispositions, and conflicts. `testPendingMetadataCoversRetainedWindowPlusBlockedIngress` saturates all 1,088 keys while the projection executor is blocked and verifies that the 64 successor Events preserve both terminal disposition and conflict state.

## Security, performance, documentation, and UI

One medium evidence finding: validation records summarized selected tests without preserving each complete reproducible command.

Resolution: `implementation-validation.md` now records the exact focused, per-class, localization-exclusion, source-scan, and build commands together with their results.
