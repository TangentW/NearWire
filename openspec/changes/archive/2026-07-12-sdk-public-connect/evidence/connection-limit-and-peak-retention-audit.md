# Connection Limit and Peak-Retention Audit

## Exact formula

`WireEventRecord.maximumDeterministicEncodedByteCount` constructs only a fixed-size maximum wrapper, subtracts the four-byte `null` placeholder, and adds the reviewed deterministic-content limit. It performs checked TTL multiplication and checked addition. It creates no payload proportional to the configured limit.

For the default V1 model:

- deterministic content: 262,144 bytes;
- exact valid record: 263,107 bytes;
- exact Event message plus frame: 263,148 bytes (36 message-wrapper bytes and 5 frame bytes);
- Event payload capacity: `max(1,048,576, 263,143)` = 1,048,576 bytes;
- secure single-send capacity: `max(1,048,581, 263,148, 65,541)` = 1,048,581 bytes;
- secure pending-send capacity: `max(4,194,304, 263,148 + 2 * 65,541)` = 4,194,304 bytes;
- active incoming retention: `max(8,388,608, 263,107)` = 8,388,608 bytes.

The exact record uses one App role and one Viewer role. Its canonical timestamp uses the longest Apple Foundation representation accepted and reproduced by the production codec. `testMaximumEventRecordBoundCoversAdversarialProductionEncodings` proves equality with a valid 262,144-byte content value and all maximum non-content fields.

## Structural and generated proof

- `EventContentCodec` produces only the seven `JSONValue` cases: null, boolean, integer, finite number, string, array, and object.
- `JSONValue.validate` bounds strings, keys, depth, collection entries, encoded content, and expanded model bytes before wire construction.
- The wire encoder embeds the validated `JSONValue` directly as `content`; it adds no content-dependent escaping outside that deterministic value.
- Fixed adversarial cases cover numeric limits, escaping, Unicode, large arrays, and large objects.
- A reproducible LCG seed (`0x4E65617257697265`) generates 256 valid trees through every JSON case at depth three; every production record remains at or below the exact bound.
- `testMaximumRecordTraversesProductionSessionCodecAtExactBoundary` sends the exact 263,107-byte record through the production session encoder and frame decoder, proves the exact 263,148-byte frame, and rejects both a one-byte-smaller negotiated Event limit and one-byte-smaller frame payload limit.
- `testExactDefaultAndHardBoundFramesFitSingleSendLimits`, `testNonisolatedMailboxAdmissionIsSynchronouslyBoundedUnderConcurrency`, `testActiveWireDrainCrossesTokenServiceByteDepthAndMailboxBounds`, `testIncomingInFlightContributesToCombinedCountAndByteLimits`, and the batch/repeated-frame overflow tests exercise the real secure-mailbox, active-turn, incoming-retention, decoder, and aggregate boundaries. `testLimitPlanUsesExactReviewedDownstreamCapacities` independently proves every public planner relationship and hard maximum.

## Simultaneous retention

The public planner does not add a second synthetic maximum payload. During uplink, the actor may retain the bounded queue item while creating one bounded record/frame; the transport mailbox then owns framed `Data` under its 4 MiB byte and 256-item bounds. One active turn is independently bounded by service units and configured accounted bytes. During downlink, the secure receive chunk, frame decoder, active incoming queue, and public stream each have separate count/byte limits; terminal transition clears transport and active queues.

No bound derives the peer network maximum from queue accounting. Raising `buffer.maximumEventBytes` changes only active-turn accounted bytes, subject to the existing 64 MiB hard maximum. This prevents an App-local buffer choice from widening decoder, wire, or peer retention.
