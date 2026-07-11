## ADDED Requirements

### Requirement: One internal process connection lease is atomic

The SDK SHALL provide one non-public process-wide connection lease registry using the permanent selector literals `com.nearwire.connection-lease.monitor` and `com.nearwire.connection-lease.owner`. The literals SHALL be independent of all release, product, protocol, schema, and build versions and SHALL never change. Any future migration SHALL coordinate all legacy owner slots under the same monitor before claim or release; an uncoordinated replacement slot is forbidden.

Each loaded NearWire image SHALL resolve and immutably retain the same private `NSObject` monitor, when bootstrap succeeds, by briefly synchronizing on `ProcessInfo.processInfo` and using the monitor selector with retain-nonatomic associated-object policy. Bootstrap SHALL create its candidate before enter, record only a selected monitor reference and primitive outcome while synchronized, and explicitly exit before constructing an available or unavailable runtime reference or releasing the losing candidate. Normal claim and release SHALL synchronize only on that private monitor and SHALL store at most one private `NSObject` reference-identity token under the owner selector with retain-nonatomic policy. Claim SHALL be synchronous, SHALL linearize all competing callers and loaded images, and SHALL return exactly one opaque live handle when the owner slot is empty and all required synchronization statuses succeed. While a token remains current, every other claim whose required synchronization statuses succeed SHALL fail with one stable safe internal `anotherConnectionIsActive` error without mutating ownership or retaining rejected caller data. Any synchronization status failure SHALL instead take precedence and produce `runtimeUnavailable`, regardless of the observed slot contents. The implementation SHALL contain no mutable Swift global, `nonisolated(unsafe)` storage, configurable alternate production registry, or force-reset API.

Bootstrap and private-monitor enter/exit statuses SHALL be checked separately. A failed bootstrap or private-monitor enter SHALL perform no associated-slot access. A failed bootstrap exit MAY already have read or installed the monitor and SHALL construct an unavailable reference after the failed call without subsequently inspecting, rolling back, releasing, or otherwise touching the association. Claim SHALL allocate its candidate token before entering the private monitor. While synchronized it SHALL perform only owner associated-object get/set and primitive outcome recording. It SHALL explicitly exit before constructing or returning a handle, constructing or throwing an error, formatting diagnostics, invoking cleanup, or calling caller-provided work. A failed private-monitor exit MAY already have read or mutated the owner slot and SHALL return no handle. Every failed claim status SHALL fail closed with the fixed safe runtime-unavailable error.

The production registry SHALL delegate to the exact internal low-level operation using only a fixed Apple-system runtime adapter and `ProcessInfo.processInfo`; neither SHALL be configurable or replaceable through production state. The operation MAY accept an internal runtime-operations value solely as a source-level testing seam, but it SHALL accept no caller closure or application content and SHALL NOT be public or SPI. Tests MAY invoke the operation with a test-only adapter and isolated `NSObject` fixture so destructive failure outcomes cannot touch or reset the process slot.

#### Scenario: Concurrent first claims

- **WHEN** many threads or tasks cross one start gate and claim an empty process registry and all required synchronization statuses succeed
- **THEN** exactly one caller receives a handle
- **AND** every other caller receives the contention error

#### Scenario: Independently loaded NearWire images

- **WHEN** two separately built dylibs containing independent copies of the lease implementation are loaded into one process
- **THEN** they resolve the same permanent selectors and private monitor
- **AND** they cannot both claim, stale cross-image release cannot clear the winner, and release permits reacquisition

#### Scenario: Contention preserves the owner

- **WHEN** a second claim fails while the first handle is live
- **THEN** the first handle remains authoritative until it releases

#### Scenario: Synchronization failure takes precedence over contention

- **WHEN** claim observes an existing owner but its private-monitor exit status fails
- **THEN** claim returns runtime-unavailable rather than contention
- **AND** the existing owner token remains identical

### Requirement: Only the exact current handle can release ownership

Each handle SHALL own the immutable private monitor reference and one private reference-identity token. Explicit release and deinitialization SHALL use the same idempotent owner-slot operation. The registry SHALL clear ownership only when the released token is identical to the current associated token. When required synchronization statuses succeed, repeated, concurrent, empty-registry, and stale-token releases SHALL be no-ops and SHALL NOT clear a newer claim. Release SHALL check monitor statuses and exit before any cleanup. A failed release enter SHALL perform no owner-slot access and SHALL leave ownership untouched. A failed release exit MAY follow a clear and SHALL provide no success or subsequent-reacquisition guarantee. Release SHALL expose no status and SHALL never create a second owner.

#### Scenario: Explicit release permits reacquisition

- **WHEN** the current handle releases with successful synchronization statuses and another caller claims with successful synchronization statuses
- **THEN** the later caller receives a new live handle

#### Scenario: Stale handle after reacquisition

- **WHEN** handle A releases, handle B claims, and A releases again, with all required synchronization statuses succeeding
- **THEN** B remains current

#### Scenario: Handle leaves scope

- **WHEN** the only reference to the current handle is deinitialized and required release and later-claim synchronization statuses succeed
- **THEN** defensive cleanup releases the registry for a later claim

#### Scenario: Release synchronization fails

- **WHEN** release enter fails
- **THEN** it performs no owner-slot access and exposes no success status
- **WHEN** release exit fails after an exact-token operation
- **THEN** it exposes no success or later-reacquisition guarantee

### Requirement: Lease state is bounded, safe, and content-free

The registry and handle SHALL retain no NearWire instance, queue, closure, continuation, task, timer, pairing code, endpoint, Viewer identity, event, or application content. The handle SHALL be concurrency-safe and its description, debug description, interpolation, describing string, and reflecting string SHALL expose only a fixed safe label. Contention and runtime-unavailable errors SHALL contain only stable codes and fixed safe messages. Selector namespaces are not secrets; same-process runtime code is inside the trust boundary and MAY reproduce or tamper with them.

#### Scenario: Handle diagnostics are rendered

- **WHEN** a handle and contention error are described or reflected
- **THEN** output contains no token identity, memory address, caller data, or application content

### Requirement: Lease work starts only through explicit connection ownership

NearWire construction, event send, stream subscription, buffer diagnostics, and clearing SHALL NOT claim or release the process connection lease. In the current disconnected implementation, no NearWire instance owns a handle, so its shutdown SHALL NOT change lease state or release another internal claimant. A later owning connection or session shutdown SHALL deterministically invoke release on its own exact handle. Successful synchronization SHALL clear ownership; a synchronization failure SHALL remain fail-closed and MAY leave connection ownership unavailable. The later public orchestrator SHALL map every internal lease error, including contention and runtime-unavailable, to supported safe SDK errors. This change SHALL add no supported public lease API and no public `connect` or `disconnect`. Claim and release SHALL start no discovery, network connection, Keychain access, persistence, handshake, rate scheduler, task, timer, App lifecycle observer, UI, or event transfer.

#### Scenario: Multiple idle instances

- **WHEN** multiple NearWire instances buffer events and use their existing public APIs
- **THEN** their instance-local behavior remains independent
- **AND** the process lease remains available for one later explicit connection owner

#### Scenario: Unrelated shutdown cannot release ownership

- **WHEN** an internal test owner holds the lease and a current disconnected NearWire instance shuts down
- **THEN** the internal owner remains current

### Requirement: Lease validation helpers cannot enter distribution

Test runtime adapters, C-callable wrappers, loader code, and generated helper binaries SHALL exist only in validation fixtures outside `SDK/Sources`, every package and pod source glob, and every distributable target. Package product and target inventories SHALL remain unchanged, production code SHALL contain no dynamic-loader path, and distributable binaries SHALL export no harness wrapper symbol. The internal runtime-operation seam SHALL remain non-public and non-SPI.

#### Scenario: Distribution artifacts are audited

- **WHEN** SwiftPM and CocoaPods artifacts and their exported symbols are inspected
- **THEN** no validation wrapper, loader, generated dylib, or test adapter is present and the internal operation is inaccessible
