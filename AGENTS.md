# NearWire Agent Guide

## Language

Write new documentation, comments, specifications, review reports, commit messages, and user-visible strings in English. Existing Chinese product planning material may remain in its original language.

## Required Change Workflow

1. Create one OpenSpec change with a narrow, testable scope.
2. Complete and validate proposal, design when applicable, capability specs, and tasks before modifying production or test source.
3. Apply tasks sequentially and mark checkboxes only after the stated evidence exists.
4. Add proportionate unit, integration, packaging, and documentation coverage.
5. Run all required validation commands and save exact results under the active change's `evidence` directory.
6. Run independent review agents for architecture/API, correctness/testing, and security/performance/documentation.
7. Record findings, fix every actionable issue, and run a fresh review round. Repeat until no unresolved finding remains.
8. Complete a spec-to-evidence audit, archive the change, and only then begin apply work for the next change.

## Repository Boundaries

- Shared platform-neutral implementation belongs in `Core`.
- iOS-specific implementation belongs in `SDK`.
- macOS Viewer implementation belongs in `Viewer`.
- The maintained integration application belongs in root `Demo`.
- Do not create another `Package.swift` or podspec below the repository root.
- Do not add third-party runtime dependencies to Core or SDK.
- Viewer-only dependencies must be attached to the Viewer Xcode project and must not appear in the root Swift Package manifest.

## Compatibility

- Build with Xcode 16 or later.
- Compile distributed source in Swift 5 language mode.
- Keep public SDK APIs compatible with iOS 16.
- Keep Viewer code compatible with macOS 13.
- Use modern Swift concurrency while maintaining explicit Sendable and isolation discipline.

## Safety and Quality

- Preserve the current active OpenSpec scope; do not broaden a change through opportunistic feature work.
- Keep bootstrap module markers internal so they cannot become accidental public API.
- Never weaken a validation command to hide a failure. Record genuine environment limitations and preserve the intended gate.
- Do not claim completion from a narrow test. Match evidence to every requirement and scenario.
