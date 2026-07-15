# Spec-to-Evidence Audit

| Requirement | Implementation evidence | Validation evidence |
| --- | --- | --- |
| Viewer has one bounded memory-only current Session and no database implementation | Former `Store` sources, SQLite bridge, database tests, Xcode Store group, and SQLite linkage are deleted; memory contracts and transfer live under `Application` | `database-residue-scan.md`; clean Viewer build; full Viewer suite |
| Clear, import, and export share one authoritative memory workspace | Clear preserves only active lanes, import atomically replaces inactive memory state, export freezes one retained snapshot, and callbacks have ordered generation ownership | Five focused workspace/transfer tests; fresh independent review |
| Event detail retains bounded Renderer but no Causality Inspector | Inspector cases are Metadata, Raw, Tree, Pretty, and Renderer; exact correlation/reply identifiers remain metadata only | Maintained-source causality scan; Renderer tests in full Viewer suite; fresh review |
| Performance consumes frozen current-memory Events and reveals exact raw identity | Memory-only dashboard driver and journal-key raw reveal replace Store traversal | Focused Performance controller publication/raw-reveal test; full Viewer suite |
| Import/export UI is truthful, sandbox-safe, and localized | Security-scoped file access spans asynchronous import; imported rows are Offline; disclosure matches the emitted schema; English and Simplified Chinese entries are complete | String catalog JSON validation and missing-translation scan; UI/security/documentation review |

Final commands all exit `0`: clean `build-for-testing`, five focused tests, the maintained Viewer suite, SQL/SQLite/project/test residue scans, `jq empty`, `git diff --check`, and strict OpenSpec validation. The optional OpenSpec PostHog flush cannot resolve its telemetry host in the restricted environment, after validation has already succeeded; it does not change the exit status.
