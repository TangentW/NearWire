# Review round 2

## Architecture/API

Result: no findings. The reviewer confirmed stable split and surviving-host identity, divider
restoration, environment forwarding, and spec alignment.

## Correctness/testing

Result: no findings. The reviewer confirmed that the revised tests close stale-reference loopholes
and cover content, locale, minimum widths, visibility transitions, and restored divider position.

## Security/performance/documentation/UI

Finding: the detached hidden panel's hosting graph remained retained by the Coordinator and could
continue observing high-frequency Event updates while offscreen.

Resolution: hiding a panel now removes and releases only that panel's `NSHostingView`. The visible
panel and split remain stable. Restoring the hidden panel creates only its hosting graph and restores
the saved divider fraction. The transition regression holds a weak reference and verifies the hidden
hosting view is released.
