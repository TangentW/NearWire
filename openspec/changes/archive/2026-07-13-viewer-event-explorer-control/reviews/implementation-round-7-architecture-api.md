# Architecture and API Implementation Review — Round 7

## ARCH-R7-001 — P2 Medium: replacement installation is not linearizable

Confidence: High

`ViewerStoreExplorerGateway.install` clears `activeGeneration` before waiting for the previous
generation and later publishes its replacement unconditionally. This permits a supported reentrant
interleaving:

1. Generation A is executing a client callback.
2. Thread T1 calls `install(B)`, detaches A, and waits for A's callback.
3. A's callback calls `install(C)`. Because the active slot is temporarily empty, C is immediately
   published and may accept work.
4. A's callback returns, allowing T1 to resume.
5. T1 unconditionally overwrites C with B.

C is never sealed or joined. Its tokens can no longer be cancelled through the gateway, its
operations disappear from gateway diagnostics, and its callback can update presentation after B
becomes active. Generation numbering can also move backwards from C to B. This violates the
originating-generation join and stale-publication contract.

Current production replacement calls are serialized by `ViewerStoreRuntime`, so the ordinary reopen
path does not independently trigger this. However, reentrant replacement is explicitly supported and
tested, while the `@unchecked Sendable` gateway does not enforce single-owner installation. The
combined supported contract is therefore unsafe.

Recommended ownership options:

- Keep `ViewerStoreRuntime` as the sole replacement owner and do not expose synchronous installation
  as a client-callback operation; or
- If reentrant installation remains supported, linearize replacement requests, allow only the exact
  winning request to publish, and seal/join every superseded candidate. A simple mutex around the
  current callback-joining implementation would deadlock against the callback being joined.

Validation must use three coordinators: block A's callback, start external B installation, install
and submit work to C from A's callback, then release A. It must prove one deterministic winner, no
orphan C callback, every losing generation sealed/joined, and zero retained operation/cancellation
state.

The round-6 shutdown, callback-retirement, controller-delivery, committed-export, and conflict-marker
fixes otherwise remain structurally sound. Module boundaries and Swift 5/macOS 13 compatibility
remain intact. `git diff --check` and strict OpenSpec validation pass. Configured signing and embedded
entitlement verification remains deferred and is not a finding.

**Unresolved findings: 1**
