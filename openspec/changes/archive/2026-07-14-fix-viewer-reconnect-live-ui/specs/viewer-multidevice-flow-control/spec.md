## MODIFIED Requirements

### Requirement: Viewer owns a finite set of independent App sessions

Viewer SHALL replace the foundation placeholder with one `ViewerAdmissionHandoffOwning` multi-device manager. The manager SHALL synchronously bound current provisional, negotiating, active, and disconnecting route owners to 16, independently from the foundation's 32 connection-owner bound, and SHALL separately bound displaced reconnect cleanup owners to 16. A rejected 17th current-owner handoff SHALL create no session task or UI row and SHALL be cancelled through the original admission cleanup ownership.

Each accepted session SHALL extend the same immutable admission connection core, secure-channel callback, continuous frame decoder, and terminal gate that decoded the App Hello. The core serial queue SHALL remain the sole decoder, wire-phase, policy-transaction, sequence, and terminal executor. Session attachment SHALL occur synchronously and reentrantly before ownership replacement commits or handoff transfer returns success, SHALL preserve another frame coalesced after App Hello, and SHALL occur at most once. It SHALL NOT expose or replace raw Network.framework objects, endpoint descriptions, decoder ownership, or transport callbacks. A failed attachment SHALL change no current or displaced route ownership. A committed replacement SHALL move the exact predecessor to bounded displaced cleanup ownership. No manager lock SHALL be held across a core operation or callback that can re-enter the manager. Per-session work SHALL be isolated so one device's wait, full queue, malformed input, or cleanup cannot serialize another device.

#### Scenario: Sixteen Apps are connected

- **WHEN** 16 current slots are occupied by any mixture of provisional, negotiating, active, or disconnecting owners
- **THEN** each has independent session and queue ownership
- **AND** a valid 17th distinct-route handoff is rejected without disturbing the first 16

#### Scenario: One device blocks

- **WHEN** one active device stops reading, fills its queue, or delays cleanup
- **THEN** another device can negotiate, exchange Events, publish telemetry, and disconnect
- **AND** no shared wait or business queue couples their progress

#### Scenario: Session attaches after admission

- **WHEN** the multi-device owner accepts an opaque admission handle
- **THEN** active protocol handling continues through the same connection core and decoder
- **AND** no unread bytes or terminal event can be stranded between owners

#### Scenario: App coalesces input after Hello

- **WHEN** App Hello and the next valid session frame arrive in one receive chunk
- **THEN** transfer installs the session handler inline before the decoder advances
- **AND** the next frame reaches the sole core protocol executor without an asynchronous holding queue

#### Scenario: Attachment cannot commit

- **WHEN** terminal state, shutdown, or an injected attachment failure wins before ownership commit
- **THEN** Viewer returns handoff failure without changing the current route owner or creating displaced cleanup ownership
- **AND** admission retains exact cancellation and cleanup ownership for the failed candidate

### Requirement: Logical device correlation is bounded and never authenticates a peer

Viewer SHALL derive a logical correlation key from the peer-declared App installation ID plus optional Bundle ID in the validated App Hello. That key, display name, version, generated alias, and nickname SHALL be unauthenticated correlation/presentation hints only. They SHALL NOT prove App identity, authorize Event delivery, or transfer connection-owned state. Viewer SHALL present at most one current connection per correlation key.

When a second admitted connection claims an exact currently owned key, Viewer SHALL make the newest session the current route owner and cancel the displaced session outside manager locks. Replacement SHALL issue a new opaque control capability and SHALL NOT transfer pending downlink work, queue keys, sequence state, session epoch, terminal state, or a delivery claim. The displaced owner SHALL remain separately owned until exact cleanup completes. Viewer SHALL retain at most 16 current owners and 16 displaced cleanup owners, SHALL allow at most one outstanding displacement per correlation key, and SHALL reject additional replacement or capacity handoffs without disturbing the current owner. Shutdown SHALL join both ownership sets.

A disconnected key MAY remain as a safe memory-only recent row for at most 30 seconds and SHALL retain no Event content, queue key, session epoch, pairing code, endpoint, certificate, or wire bytes. Recent rows SHALL be globally bounded to 64, deterministically evict the oldest disconnect time with correlation-key tie-breaking, and never evict a current/displaced connection. Exactly one manager-owned replaceable wake SHALL target the earliest expiry and service at most 64 due rows per turn. A successful handoff commit before the deadline SHALL replace the exact row, while failed attachment SHALL preserve it until its original deadline; at a sampled time equal to or later than the deadline, expiry SHALL win. Late callbacks SHALL match immutable connection and disconnect generations. Shutdown SHALL leave zero current owners, displaced owners, recent rows, and expiry-wake ownership after cleanup.

#### Scenario: Exact tuple reconnects while the predecessor is owned

- **WHEN** a second paired and TLS-admitted peer declares the same installation ID and optional Bundle ID while the original connection is owned
- **THEN** Viewer presents the new session as the current route and cancels the displaced session
- **AND** the new session inherits no queue, capability, sequence, epoch, terminal, or delivery state from the predecessor

#### Scenario: Replacement cleanup is still pending

- **WHEN** another exact-route connection arrives before the displaced predecessor finishes cleanup
- **THEN** Viewer rejects that additional handoff without disturbing the current route owner
- **AND** current plus displaced ownership remains within its fixed bounds

#### Scenario: Bundle variant creates a distinct key

- **WHEN** a peer declares the same installation ID but a different or missing Bundle ID from the original key
- **THEN** Viewer treats it as a separate unauthenticated correlation row subject to ordinary capacity and admission
- **AND** it neither disturbs nor inherits the original nickname, selection, session, or downlink queue

#### Scenario: Recent-route churn exceeds its bound

- **WHEN** more than 64 distinct keys disconnect within 30 seconds
- **THEN** Viewer retains at most 64 recent rows using deterministic oldest-first eviction without evicting current or displaced ownership
- **AND** one manager expiry owner services all remaining rows

#### Scenario: Reconnect reaches the expiry boundary

- **WHEN** a handoff for a recent key is processed before its deadline
- **THEN** a successful ownership commit removes the exact old row and starts a fresh unauthenticated connection
- **AND** failed attachment preserves the row, while at or after the deadline expiry wins before any later handoff
