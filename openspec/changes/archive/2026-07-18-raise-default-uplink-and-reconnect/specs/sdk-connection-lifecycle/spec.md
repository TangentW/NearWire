## MODIFIED Requirements

### Requirement: Reconnection policy is exact, default-enabled, and intent-bounded

The SDK SHALL expose `NearWireReconnectionPolicy` as a public `Equatable, Sendable` struct with
public static `automatic` and `disabled`; public read-only `isEnabled`, `maximumAttempts`,
`initialDelay`, and `maximumDelay`; and a throwing public initializer taking
`maximumAttempts: Int`, `initialDelay: Duration = .seconds(1)`, and
`maximumDelay: Duration = .seconds(30)`. Automatic SHALL expose true, 20 attempts, one-second
initial delay, and 30-second maximum delay. Disabled SHALL expose false, zero attempts, and zero
delays. The initializer SHALL create only an enabled policy and accept attempts in `1...20`, initial
delay from 100 milliseconds through 60 seconds, and maximum delay from initial delay through 300
seconds. Exact checked Duration-to-nanosecond validation SHALL fail with `invalidConfiguration` at
fixed fields `reconnectionPolicy.maximumAttempts`, `reconnectionPolicy.initialDelay`, or
`reconnectionPolicy.maximumDelay`.

`NearWireConfiguration` SHALL expose public read-only `reconnectionPolicy` and use a
source-compatible trailing initializer parameter defaulted to `.automatic`. Enabled-policy attempt
`n` SHALL wait `min(maximumDelay, initialDelay * 2^(n - 1))` with cap-before-multiply arithmetic.
The attempt count SHALL be a total budget for one intent, reset only by successful initial connect
or explicit resume, and SHALL NOT reset when an automatic attempt briefly reaches connected.
Exhaustion SHALL clear intent and leave no delay or route work. Explicit `.disabled` SHALL perform
no automatic attempt; explicit resume SHALL authorize exactly one immediate attempt and preserve
intent after a transient failure.

#### Scenario: Existing App uses defaults

- **WHEN** an App uses the source-compatible default configuration and an active route fails
  transiently
- **THEN** attempt one is scheduled after one second and later attempts use bounded exponential
  backoff through the 20-attempt budget

#### Scenario: App explicitly disables recovery

- **WHEN** an App constructs configuration with `.disabled` and an active route fails transiently
- **THEN** no automatic delay or replacement starts and intent remains available only for explicit
  resume or disconnect

#### Scenario: Flapping Viewer repeatedly reaches connected

- **WHEN** each automatic replacement connects and immediately ends transiently
- **THEN** the intent-wide attempt number continues increasing, work stops at the configured total,
  and brief success never resets the budget

#### Scenario: Invalid policy is constructed

- **WHEN** an attempt count or exact Duration is outside its range or maximum is below initial
- **THEN** configuration fails at its fixed field before a NearWire instance or side effect exists

## RENAMED Requirements

- FROM: `### Requirement: Reconnection policy is exact, default-disabled, and intent-bounded`
- TO: `### Requirement: Reconnection policy is exact, default-enabled, and intent-bounded`
