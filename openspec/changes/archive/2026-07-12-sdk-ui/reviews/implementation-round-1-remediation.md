# SDK UI Implementation Round 1 Remediation

Date: 2026-07-12

All Round 1 findings were treated as actionable. The original reports remain unchanged; this file records the remediation to be independently re-reviewed.

## Architecture and API

- Prevented rapid repeated Connect from overwriting the accepted origin token by rejecting model activation while an exact token is already live. A back-to-back activation test proves one invocation and retained failure delivery.
- Replaced asynchronous termination/deinit cleanup with a synchronously locked internal coordinator storage. Natural iterator termination removes the exact subscriber immediately by key and token. Model deinitialization synchronously removes its registration and cancels its exact Connect without creating a cleanup Task. Non-idle entries still retain the exact controller through their one operation Task, protecting object identity until terminal completion.
- Strengthened distribution parity from name/subset checks to normalized Swift API declaration-tree equality between SwiftPM NearWireUI and the CocoaPods UI aggregate. The aggregate-minus-SDK USR set may contain declarations only below the two approved view trees. Source validation rejects every additional public line and includes top-level/member mutation self-tests.

## Correctness and Testing

- Shutdown now wins before every coordinator phase and exposes no action.
- Added direct natural-stream termination, synchronous initial phase, all ownership reset codes, both healthy-status/action-error winner orders, origin-only failure delivery, multibyte model forwarding, rapid duplicate activation, shutdown-by-phase, burst release, release-during-Connect, iOS test-source compile, and richer large-Dynamic-Type rendering coverage.
- The Round 1 high test failure referred to an intermediate test that attempted to keep a controller alive only through a subscriber registration, contrary to the model ownership contract. That probe was corrected to retain the controller through explicit unsubscribe. The subsequent storage remediation now also removes natural terminations without requiring the controller, closing the underlying stale-entry concern independently of that corrected test.

## Security, Performance, Accessibility, and Documentation

- Natural termination and model deinit no longer enqueue cleanup Tasks. A 100-model burst proves immediate zero coordinator entries, and release during Connect proves synchronous subscriber removal plus exact cancellation.
- Reconnect attempt and paused text now enter the final combined accessibility label. Tests assert the exact value.
- `ImageRenderer` uses `nsImage` on macOS and `uiImage` on iOS. Both public views and representative reset/error/progress connection-panel shapes render at accessibility Dynamic Type size. The entire iOS 16 test source graph compiles under complete concurrency checking and warnings as errors before simulator execution.
- Documentation now distinguishes retaining the injected facade from lifecycle ownership, discloses the one cancelled in-flight bounded argument copy, and explicitly disclaims secure String zeroization.
- Public surface and resource audits were refreshed to match the exact implementation.

## Fresh Validation

- Focused NearWireUI strict suite: 36 passed, zero failed.
- Full macOS strict suite: 463 executed, seven existing skips, zero failures on unchanged rerun.
- iOS 16 all-test-source strict compile: passed.
- iOS 16/macOS 13 NearWireUI strict target builds: passed.
- SwiftPM/CocoaPods consumers, forbidden fixtures, normalized aggregate API equality, and structure mutation tests: passed.
- Strict active change and all 25 repository spec validations: passed.
- Swift format strict lint, English scan, boundary suite, version, structure, and diff checks: passed.
- Simulator execution and `pod lib lint` remain blocked only by the sandboxed CoreSimulator service and require the final unrestricted gate.
