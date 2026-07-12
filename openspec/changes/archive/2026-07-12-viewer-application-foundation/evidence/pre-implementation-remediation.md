# Pre-Implementation Review Remediation

Date: 2026-07-12

The first lightweight review round found five unique issues across the three dimensions. The artifacts now define:

- one runtime-wide 32-slot admission capacity reserved before channel claim and shared across listener replacement;
- one non-resetting 10-second claim-to-terminal deadline for automatic and confirmation policies;
- a total policy, pause, replacement, timeout, and shutdown transition table;
- one permanent Viewer admission connection core that owns the immutable channel callback, continuous decoder, Viewer Hello, negotiation state, terminal gate, and opaque consumer handoff;
- a fixed renewable P-256/SHA-256 X.509 v3 profile and exact data-protection Keychain selectors/reset scopes;
- server-only App Sandbox entitlement, local-network and Bonjour declarations, Viewer-owned Device ID privacy manifest, and nearby-discovery disclosure.

Round 2 architecture/API, correctness/testing, and security/performance/documentation reviews each approved the artifacts with exactly zero unresolved actionable findings. Strict OpenSpec validation, English validation, and `git diff --check` pass. Production and test source remain untouched by this active change at this gate.

Post-implementation review superseded the planned data-protection Keychain selector with the standard per-user macOS login Keychain. A later security review correctly rejected the ad-hoc cross-update persistence claim and required stable Apple Development or Developer ID signing for maintained builds. The current decision and remaining executable evidence gate are recorded in the active design, capability spec, and Round 3 remediation state.
