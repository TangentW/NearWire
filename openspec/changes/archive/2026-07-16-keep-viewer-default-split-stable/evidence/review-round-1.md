# Review round 1

## Architecture/API

Finding: hiding either Event panel switched the entire workspace between split and direct-render
branches, recreating the surviving panel.

Resolution: the native split representable now remains mounted whenever at least one panel is
visible. It removes and restores only the affected arranged hosting view, preserving the surviving
hosting identity and the last divider fraction.

## Correctness/testing

Findings:

- the update test could read a stale detached split without proving hosted content changed;
- minimum divider clamps were not exercised;
- locale propagation covered only initial creation.

Resolutions:

- every update now reacquires the live split and asserts object identity;
- a hosted probe verifies content token and locale changes;
- tests exercise both minimum-width clamps;
- both-to-single-to-both transitions assert split and surviving-host identity, full-width expansion,
  and divider restoration.

## Security/performance/documentation/UI

Result: no actionable findings. The reviewer confirmed bounded update cost, retained hosting views,
locale/color-scheme propagation, native divider behavior, macOS 13 compatibility, and screenshot
quality.
