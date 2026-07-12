# Retention and Resource Audit

- The actor owns at most one pending/active intent capsule.
- Admission receives a one-shot pairing transfer; active owner, coordinator, cleanup receipt, delay Task, status, Event, error, and diagnostic values contain no pairing code.
- The actor owns at most one recovery Task. Its closure captures only a weak actor reference, task token, generation, attempt, delay, and sleeper.
- Disconnect, suspension, and shutdown explicitly cancel delay work. Successor work waits for completion or fails authorization after a held non-cooperative test sleeper returns.
- One route owns one cleanup receipt and one shared completion Task. The actor has no per-caller continuation array.
- The actor owns at most one spontaneous-terminal cleanup marker, containing only the exact route token and a reference to that route's existing receipt. The coordinator callback captures the actor weakly and contains no pairing code.
- One active route owns one terminal coordinator and one process lease. Replacement starts only after old release delivery.
- The intent-wide total attempt budget does not reset on brief connected success. Exhaustion clears intent and recurring work.
- The SDK adds no platform lifecycle observer, reachability monitor, background execution request, persistence, log, analytics, product, target, subspec, entitlement, privacy declaration, or runtime dependency.
- Offline queue, secure mailbox, decoder, incoming FIFO, and subscriber buffers retain their previously reviewed independent bounds.
