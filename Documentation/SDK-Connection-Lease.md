# SDK Process Connection Lease

NearWire contains one internal process-wide connection lease. The lease does not make `NearWire` a singleton: App code may create multiple independent instances, buffer events, and subscribe to their streams. Only an explicit `connect(code:)` call or one generation-current lifecycle recovery attempt may claim the lease, because one App process may own at most one Viewer connection attempt or active Viewer session.

The lease itself is not supported SDK API or SPI and exposes no handle. Public connect and lifecycle recovery compose it internally; constructing or using an idle `NearWire` instance never touches lease state. Public disconnect and suspension cancel only exact current ownership and await a shared cleanup receipt after the exact release invocation.

## Process-wide identity

Two permanent Objective-C selector namespaces identify the shared monitor and its current owner slot:

```text
com.nearwire.connection-lease.monitor
com.nearwire.connection-lease.owner
```

These names are independent of SDK, product, protocol, schema, and build versions. They must not change between coexisting NearWire binaries. A new uncoordinated namespace would allow two framework images in one App process to believe they both own the connection.

Each loaded NearWire image briefly synchronizes on `ProcessInfo.processInfo` the first time an explicit or lifecycle-recovery attempt claims. That bounded bootstrap reads or installs one private retained `NSObject` monitor. All ordinary claims and releases synchronize only on the private monitor; they do not keep using the public ProcessInfo singleton.

## Claim and release behavior

A claim creates one private reference-identity token before entering the monitor. If the owner slot is empty, the operation stores the token, exits the monitor, and returns an opaque internal handle. If another token exists and synchronization succeeds, it exits and returns the fixed internal contention error. Any synchronization status failure takes precedence and returns the fixed runtime-unavailable error without returning a handle.

The handle releases ownership only when its token is still the exact current token. Explicit release and deinitialization use the same idempotent operation, so repeated, concurrent, empty, and stale releases cannot clear a newer owner. Release has no status result. A failed enter leaves the owner slot untouched; a failed exit may follow a clear but makes no later-reacquisition guarantee. The current public terminal coordinator invokes exact-handle release after observed terminal state, and public connection orchestration maps both internal claim errors to supported safe SDK errors.

The monitor protects only associated-object access and primitive outcomes. Handle and error construction, diagnostics, cleanup, callbacks, tasks, and application work occur outside the monitor. The handle retains no `NearWire` instance, event, queue, closure, task, timer, endpoint, pairing code, or Viewer identity. Its diagnostics are fixed and content-free.

## Trust and distribution boundary

The selector namespaces are coordination identifiers, not secrets. Code already executing inside the App process is part of the trust boundary and can reproduce or tamper with Objective-C runtime state. Exact-token identity protects NearWire from stale handles; it is not a sandbox against hostile in-process code.

Tests cover deterministic sequential, concurrent, stale-token, deinitialization, and synchronization-failure behavior without a production reset API. A macOS integration harness separately builds and loads two dynamic libraries containing independent copies of the production lease source. It proves that both images resolve the same private monitor and cannot own the slot simultaneously. Harness wrappers, loader code, and generated libraries remain outside SDK source globs and package products.
