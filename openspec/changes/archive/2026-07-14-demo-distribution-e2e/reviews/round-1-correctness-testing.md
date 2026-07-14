# Round 1 Correctness and Testing Artifact Review

Verdict: changes required.

## Findings

1. Split reusable Reset from terminal shutdown and define exact joined cleanup ordering.
2. Keep the exact incoming Event on the production loop stack, but add a cancellation and current-generation gate after the domain callback and before mutation or reply.
3. Define an explicit operator action for Event-stream restart and cover overflow, replacement, repetition, and Reset races.

Normal/latest sending, direction filtering, byte/history bounds, Performance composition, public facade use, and the existing production exchange partition were otherwise testable.
