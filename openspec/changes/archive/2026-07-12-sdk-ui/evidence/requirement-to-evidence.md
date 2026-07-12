# Requirement-to-Evidence Matrix

| Requirement | Implementation | Automated evidence |
| --- | --- | --- |
| Exact injected two-view API | `NearWireConnectionView.swift`, `NearWireConnectionStatusView.swift` | SwiftPM/CocoaPods consumers, forbidden internal/UI fixtures, explicit API schema and structure gate |
| Construction and host lifecycle ownership | Stateless public wrapper; `NearWireUIConnectionModel.start/stop` | Construction, repeated start/stop, release, and connected-disappearance tests |
| Bounded memory-only pairing input | `NearWireUIInputLimiter`, model clearing boundaries | 63/64/65 ASCII; exact/short 2-, 3-, and 4-byte scalar; decomposed sequence; joined emoji; exact forwarding tests |
| Exact cooperative operation bounds | `NearWireUIOperationCoordinator` | Deduplication, two panels, cross-panel token reconciliation, repeated Disconnect, disappearance-only cancellation, fail-closed hold, reentrant cancellation, reverse-delivery convergence, and both acknowledgement orders |
| Conservative action matrix | `NearWireUIConnectionModel.actionPresentation` | Every SDK active/progress state, suspended, shutdown, error-free disconnected, terminal error shapes, and ownership reset tests |
| Safe complete accessible status/error | `NearWireUIPresentation`, both views | Every state/label/hint/icon/progress/color test, retry/suspension test, safe unknown error test, action-error winner test, `ImageRenderer` accessibility-size smoke test, fixed-English source audit |
| Optional resource-safe distribution | Package target, existing `NearWire/UI` subspec, boundary scripts | iOS 16/macOS 13 strict builds, SDK-only forbidden fixture, UI consumers, aggregate inventory, no-forbidden-resource audit |
| Replacement resets ownership | Wrapper `.id(ObjectIdentifier(nearWire))`; model generations/tokens | Mounted public-view replacement transfers the real SDK status subscription from A to B; distinct-controller replacement proves predecessor events are inert and successor actions use only the successor |

The exact final commands and results are in `focused-implementation-validation.md`. The complete Swift Package, iOS simulator, and CocoaPods gates passed.
