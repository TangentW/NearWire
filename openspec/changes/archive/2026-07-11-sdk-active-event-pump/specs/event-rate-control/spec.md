## ADDED Requirements

### Requirement: Captured whole-token allowance has a prevalidated commit

The token bucket SHALL expose one internal SPI-only nonthrowing prevalidated consumption operation for cross-target active-session composition. Its caller SHALL first refresh a value copy at one monotonic selection time and capture that copy's whole-token allowance. With no intervening mutation, a nonnegative accepted count no greater than that allowance SHALL subtract exactly that count from the copy without another clock observation, refill, throwing calculation, or rate decision.

The operation SHALL remain outside supported SDK API. Passing a negative count, a count above the captured allowance, or a differently mutated bucket SHALL be a repository programmer-contract violation and SHALL never derive directly from peer input. Production active pumping SHALL establish the contract by bounding actor acceptance to the captured allowance before any mailbox commit.

#### Scenario: Byte bound shortens an allowed prefix

- **WHEN** a refreshed bucket copy reports ten whole tokens but the active drain accepts three Events
- **THEN** prevalidated commit subtracts exactly three tokens from that same copy without failure
- **AND** the seven unused whole tokens remain subject to the bucket's normal fractional and capacity state

#### Scenario: Captured allowance is exhausted

- **WHEN** the active drain accepts exactly the whole-token allowance passed to it
- **THEN** prevalidated commit succeeds without a second time sample
- **AND** no later Event in that drain can have entered the mailbox
