# Round 1 Architecture and API Artifact Review

Verdict: changes required.

## Findings

1. The Xcode App consumer cannot rely on `SWIFT_PACKAGE`; define a SwiftPM-App-only condition that guards only the separate UI and Performance imports.
2. Copying only `Demo` breaks the project's relative local-package reference; preserve the required repository root topology during CocoaPods validation.
3. Reusable Reset cannot promise joined terminal `shutdown()` cleanup; use awaited `disconnect()` for Reset and keep synchronous `shutdown()` terminal.
4. A duplicated Xcode `MARKETING_VERSION` literal is not dynamically sourced from `VERSION`; require equality and extend the validation gate.

The remaining ownership, project, public API, host declaration, and distribution decisions were considered feasible. Configured signing remains deferred to `release-hardening`.
