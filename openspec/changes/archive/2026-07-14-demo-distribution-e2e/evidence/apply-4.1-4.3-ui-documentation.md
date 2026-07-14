# Demo UI and Documentation Evidence

## Result

Tasks 4.1 through 4.3 passed on 2026-07-14.

The SwiftUI surface injects one `NearWire` instance into `NearWireConnectionView` and exposes the Event lab, newest Viewer-control summaries, queue diagnostics, Performance controls, and confirmed reset. Text input is bounded before send. Status is expressed in text, controls have deterministic English accessibility identifiers and hints, and the scroll-based layout remains keyboard safe.

The Demo adds no Event or pairing clipboard, log, share, export, or persistence surface. `Demo/README.md` documents the SwiftPM and CocoaPods workflows, pairing semantics, Event and control schemas, causal reply, local-only diagnostics, Performance opt-in, privacy bundles, generated-state cleanup, and the configured-signing exclusion. The root README links to it.

## Commands and exact outcomes

```sh
swift format lint --strict --recursive Demo
# exit 0; no findings

bash Scripts/verify-english.sh
# CJK character scan passed. Human review remains required for semantic language compliance.
```
