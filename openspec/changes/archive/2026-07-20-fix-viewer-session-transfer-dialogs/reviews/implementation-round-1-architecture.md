# Architecture and API Review — Round 1

## Findings

1. Panel completion depended on coordinator lifetime and could be lost during teardown.
2. A delayed callback from a replaced panel could clear ownership of the current panel.
3. Losing or changing the anchored window did not directly close its active panel.

## Resolution

The coordinator now owns an exactly-once request object. Window changes cancel the active request,
replacement resolves the predecessor before installing the successor, and delayed callbacks can
resolve only their own request. A focused injected-presenter test covers replacement and window
detachment.
