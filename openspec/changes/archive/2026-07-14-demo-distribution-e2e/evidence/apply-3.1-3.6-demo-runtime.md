# Demo Runtime Evidence

## Result

Tasks 3.1 through 3.6 passed on 2026-07-14.

`DemoModels.swift` owns the fixed Demo Event names, Sendable Codable payloads, exact 512-byte UTF-8 limiter, local presentation values, and newest-50 summary buffer. `DemoDriver.swift` is the only Demo production adapter and calls only public `NearWire`, `NearWireEvent`, and `NearWirePerformanceMonitor` APIs.

`DemoApplicationModel` is MainActor-isolated and owns one optional Event task and one optional Performance-state task. Activation is idempotent. Reset increments the generation, clears the stored task references, cancels and joins both tasks, stops sampling, awaits disconnect, clears state, and explicitly restarts observation. Terminal teardown adds `shutdown()` after reusable disconnect. Generation checks reject stale deliveries.

The ordinary `demo.message`, keep-latest `demo.counter`, exact-source `demo.control.result` reply, queue diagnostics, banner validation, and explicit Performance Start/Stop paths are present. Presentation text consistently describes local queue acceptance and never claims remote delivery. The Demo contains no transport, timer, retry engine, persistence layer, or generic registry.

## Structural checks

```sh
ruby Scripts/check-swift-boundaries.rb
# Swift module import boundaries passed.

swift format lint --strict --recursive Demo
# exit 0; no findings
```
