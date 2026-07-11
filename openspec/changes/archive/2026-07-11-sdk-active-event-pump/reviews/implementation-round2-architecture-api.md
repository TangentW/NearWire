# Post-Implementation Architecture and API Review — Round 2

## Findings

### 1. HIGH — Continuous owner signals can starve a valid initial policy until timeout

**Evidence**

- During policy negotiation, every outbound hint sets `outboundWorkRequested`; if no refresh is running, it starts an owner-schedule refresh (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:600-628`).
- A complete initial offer is deferred whenever a refresh is installed or another outbound hint is latched (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1076-1111`).
- When a live refresh completes, the core gives `outboundWorkRequested` or `dueWorkRemains` unconditional priority and immediately starts another refresh. It considers the already buffered initial offer only when both are false (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:631-665`). Successful sends can continuously relatch the bit, including while each prior refresh is suspended, so this chain has no bound tied to the policy FIFO or its deadline.
- The initial-policy deadline remains live until activation (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:529-534`; `openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:52-58`). Therefore sustained App traffic can make a valid, fully received offer fail with `policyNegotiationTimedOut` even though every refresh reports a live owner.
- The current live-result test releases one refresh without injecting another signal and therefore proves only the single-refresh case (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:1029-1075`).

**Impact**

Business-Event queue hints can indefinitely outrank the Control transaction required to activate the session. A high-rate producer can prevent connection establishment and turn ordinary local App traffic into a policy timeout. This also conflicts with the architecture in which the callback is only a coalesced hint and policy transactions prevent new Event selection until they commit.

**Required remediation**

After a matching refresh returns `.available`, activate the oldest buffered initial offer before servicing another live-work hint. Preserve or relatch the hint and any `dueWorkRemains` state so bounded queue maintenance resumes immediately after activation. Keep `.ownerUnavailable`, `.clockFailed`, and terminal-first outcomes ahead of policy acceptance. Add a deterministic signal-storm test that relatched work during every held live refresh, injects one valid initial offer, and proves activation completes without waiting for the storm to stop.

### 2. MEDIUM — Wake registration commits an entire expiry batch under one operation-gate claim

**Evidence**

- `registerOutboundWorkWake` acquires `SDKActiveOperationGate` once and, while that one claim remains held, assigns the callback, samples the clock, runs the complete bounded scheduling observation, and directly commits every due expiration (`SDK/Sources/NearWire/NearWire.swift:446-479`). Its `authorizeExpiration` closure calls `commit()` without making another gate claim (`SDK/Sources/NearWire/NearWire.swift:465-469`).
- `observeActiveSchedule` may remove up to `maximumServiceUnits` Events in that call (`Core/Sources/NearWireFlowControl/BoundedEventQueue.swift:516-569`). Because terminal close cannot acquire the gate between those removals, the first registration claim makes the whole batch one committed-before-terminal transaction.
- The normative contract instead requires wake registration and **each expiration** to claim the shared gate separately around only its own small irreversible mutation (`openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:122-130`). The queue delta likewise requires separate authorization claims and says terminal before one expiry leaves that Event unchanged and permits no later mutation (`openspec/changes/sdk-active-event-pump/specs/bounded-event-queue/spec.md:3-27`). The design explicitly keeps complete turns outside the gate (`openspec/changes/sdk-active-event-pump/design.md:80-90`).
- Current registration tests cover a prebuffered live candidate, a closed gate, shutdown, and exact-token removal, but do not put multiple due Events in registration's initial snapshot or close terminal between two expiry commits (`SDK/Tests/NearWireTests/NearWireBufferTests.swift:10-112`).

**Impact**

Terminal cleanup can be blocked behind up to the hard service quantum of clock, heap, expiry, live-ID, accounting, telemetry, compaction, and fair-planning work. More importantly, the implementation removes the specified legal ordering in which one expiry commits and terminal wins before the next; all registration-time expiries are incorrectly treated as a single side effect.

**Required remediation**

Capture callback assignment plus a nonmutating owner/schedule snapshot under the registration claim. If the snapshot reports due work, service it in the follow-up refresh path, where every expiration uses its own gate claim. Alternatively split observation preparation from per-item commits without nesting the non-recursive gate. Add a barrier test with at least two due Events that lets the first expiry commit, closes terminal before the second claim, and proves the second Event and its related values remain unchanged.

### 3. MEDIUM — The active dependency object does not provide the specified fixed live operation boundary

**Evidence**

- `SDKActiveEventPumpDependencies` currently contains two sleep closures, several before-completion hooks, and one generic operation-gate hook (`SDK/Sources/NearWire/Session/SDKActiveEventPump.swift:9-57`). It does not expose the bound session clock or fixed closures for wake installation/removal, schedule observation, drain, mailbox capacity/admission/completion, or incoming publication.
- The permanent core instead calls the retained `NearWire` and `SecureByteChannel` objects directly for all of those operations, including clock reads, registration, schedule refresh, drain, capacity checks, and publication (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:542,622,982,1148,1236,1276-1302,1379,1453,1502,1555,1606`).
- The approved design says this dependency type supplies Sendable closures bound to the exact owner and channel for those operations (`openspec/changes/sdk-active-event-pump/design.md:156-160`). The normative specification additionally requires barrier-capable seams for assignment/removal, drain entry/return, candidate/expiry/route claims, mailbox admission/capacity/completion, publication entry/claim, observer cancellation, and terminal close (`openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:297-305`).
- A generic gate hook cannot target one operation kind, and the current before-hooks do not control direct actor entry, mailbox admission/capacity, wake removal, observer cancellation, or terminal close. Tests consequently rely on concrete fake owners/channels and global gate hooks instead of the fixed per-session dependency boundary prescribed by the change.

**Impact**

The active core is more tightly coupled to actor and transport implementations than the approved architecture, and several exact reentrancy orderings cannot be isolated at their intended boundary. That makes operation-specific race tests fragile and leaves future owner/channel substitutions able to bypass the invariant-preserving live adapter rather than changing one fixed dependency surface.

**Required remediation**

Bind one immutable live dependency value to the exact `NearWire`, channel, session clock, and shared gate before active mutation. Route the specified owner and mailbox operations through typed Sendable closures, with operation-specific test barriers that do not bypass production validation or gate claims. If direct object calls are intentionally preferred, revise the design and normative requirement in a separately reviewed OpenSpec change before claiming this change complete.

## Unresolved Count

**3 unresolved findings: 1 High and 2 Medium.** Architecture/API closure is not granted.
