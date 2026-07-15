# Specification-to-Evidence Audit

## Singleton Performance window and stable Main workspace

Implemented by `NearWireViewerApp`, `ViewerRootView`, and `ViewerPerformanceDashboardView`.
SwiftUI source checks, render tests, and launched accessibility inspection prove one auxiliary
Performance window, no embedded mode picker, stable Event panels, Device picker, Show Viewer, and
minimum-size recovery states.

## Independent bounded traversal ownership

Implemented by `ViewerExplorerQueryArbiter`, `ViewerStoreExplorerGateway`,
`ViewerEventExplorerCoordinator`, `ViewerPerformanceDashboardController`, and
`ViewerAnalysisModeCoordinator`. Arbiter and Store integration tests prove one Event traversal and one
Performance traversal under the existing serialized gateway, surface-specific release, and joint
Store replacement/shutdown cleanup.

## Independent Performance Device selection

Implemented by `ViewerAnalysisModeCoordinator` and the Performance toolbar. Coordinator and SwiftUI
tests prove deterministic fallback, same-name disambiguation, invalid-choice clearing, process-only
retention, and no mutation of Event Device scope.

## Exact raw Event reveal

Implemented by `ViewerAnalysisModeCoordinator`, `ViewerEventExplorerController`, and the raw resolver.
Tests prove active and paused Event snapshot refresh, preserved frozen Timeline rows, exact durable and
transient preflight, missing-detail rejection, unchanged prior Inspector on failure, post-await stale
transition rejection, Store cancellation/join, unchanged Performance presentation and ledger, and
exactly one successor projection after Resume.

## Publication, animation, privacy, and cleanup

Region signatures and stable window roots prevent unrelated reconstruction. Performance suspension
retains the last complete immutable presentation instead of publishing an empty intermediate state.
Publication tests, full-suite cleanup tests, strict-concurrency build, UI review, and security review
prove bounded cadence, content-free ownership/reflection, no new export or clipboard sink, and zero
unjoined work after cleanup.

## Documentation and compatibility

Viewer architecture, Event Explorer, Performance, implementation roadmap, and README documentation
describe the two-window model and independent selection. The final builds passed in Swift 5 language
mode with macOS 13 and iOS 16 deployment constraints unchanged.

All modified requirements and scenarios have implementation and validation evidence. No known gap or
unresolved finding remains.
