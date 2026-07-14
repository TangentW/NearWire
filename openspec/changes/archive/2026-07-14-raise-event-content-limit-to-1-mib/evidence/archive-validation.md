# Archive Validation

Date: 2026-07-15 (Asia/Shanghai)

1. `openspec archive raise-event-content-limit-to-1-mib --yes`
   - Exit status: 0
   - Result: three requirements were added, five complete requirements were modified, and the
     change was archived as `2026-07-14-raise-event-content-limit-to-1-mib`.
2. Canonical-spec inspection confirmed both active-pump requirements use 4,259,840 bytes, Viewer
   admission uses the production Event-record capacity, Event framing uses 2 MiB, and the Event
   model uses the 1,048,576-byte content boundary.
3. `openspec validate --all --strict`
   - Exit status: 0
   - Result: 33 specs passed, 0 failed.
4. Archive-added blank lines at EOF were removed without changing requirement content, and
   `git diff --check` exited 0.

The archive command reported the final completion task as pending because that task included the
archive, commit, and push operations themselves. Scoped commit `0e0ad48` was subsequently created
and pushed to `origin/main`, so the archived task is now complete. Optional PostHog telemetry does
not affect local strict validation.
