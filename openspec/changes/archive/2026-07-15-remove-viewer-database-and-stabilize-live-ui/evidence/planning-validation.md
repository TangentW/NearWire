# Planning Validation

Command:

```text
openspec validate remove-viewer-database-and-stabilize-live-ui --strict
```

Result: exit status `0`.

```text
Change 'remove-viewer-database-and-stabilize-live-ui' is valid
```

The CLI subsequently reported that optional PostHog telemetry could not reach `edge.openspec.dev` in the restricted environment. That telemetry flush failure did not affect validation and the command exited successfully.
