# Requirement-to-Evidence Map

| Requirement | Primary implementation | Tests and evidence |
| --- | --- | --- |
| Explicit public connect and precedence | `NearWire.connect`, exact actor slot, public error mapping | Public orchestration preflight, cancellation, shutdown, overlap, success, active-state tests; public consumer fixture |
| Constant-space least-privilege limits | `SDKPublicConnectionLimitPlan`, `WireEventRecord` and `WireSessionCodec` exact formulas | adversarial equality, 256 seeded trees, downstream capacity test, `connection-limit-and-peak-retention-audit.md` |
| Bounded App hello metadata | `SDKProductVersion`, `SDKHostApplicationMetadata` | version gate, metadata fallback/omission test, production TLS hello equality |
| Exact installation identity | `SDKInstallationIdentityStore` and live Security adapter | full transcript and live-constant tests, `keychain-security-audit.md` |
| Minimal pairing retention | one-shot `SDKPairingCodeTransfer`, narrow admission/discovery constructors | public transfer one-shot test; admission ownership snapshot at blocked discovery; source/retain-graph audit |
| Shared cancellation authority | `SDKSessionTransitionGate` and one-shot targets | direct delivery, repeated request, stale replacement, both nested-handler orders, async result-boundary, and critical-section tests |
| Synchronous connecting authorization | admission phase observer plus gate checks | shutdown-held phase observer proves zero channel construction |
| One lifetime and terminal coordinator | shared lifetime/gate, one-shot termination registration, fail-closed coordinator | terminal winner tests, wait-failure vault test, active terminal test, ownership audit |
| Active binding does not retain App | weak owner closures and value-captured rates | final-App-release test and retain-graph audit |
| Exact states and safe errors | actor state commits and exhaustive fixed mapping | all internal codes mapping test, state stream tests, content-free error assertions |
| Terminal fail-closed lease cleanup | one-shot process handle, public lease, coordinator vault | low-level and facade runtime matrices, public wrapper exact-release test, child-process real-lease wait-failure contention, public real-lease contention/reacquisition |
| No lifecycle policy | single explicit attempt, no retry/background observer | source inventory, documentation, absence from public API inventory |
| Packaging and production integration | root SwiftPM/podspec Security linkage | package/podspec gates; supported public-connect loopback TLS with bidirectional Events |

All capability scenarios are represented by at least one named test or a static inventory above. Final zero-finding review reports and the spec-to-evidence audit are added before archive.
