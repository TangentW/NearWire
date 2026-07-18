# NearWire Viewer Memory Session

## Product boundary

The Viewer owns one current Session for the lifetime of the running process. Received Events,
Device metadata, diagnostics, Inspector content, and Performance inputs are retained only in a
bounded in-memory projection. The production runtime does not create, open, recover, query, clean,
or close a SQLite database for Sources or Sessions.

Closing or restarting the Viewer starts with an empty Session. The only way to carry a Session
between processes is an explicit JSON export followed by an operator-selected import. Viewer
identity and user preferences remain separate from received Session content.

The Viewer target has no SQLite linkage, SQL schema, database connection wrapper, Session catalog,
retention worker, or database-only test target.

## Memory bounds

The current Session retains at most:

- 256 MiB of deterministically accounted Event data;
- 16 Device-session metadata lanes;
- a 2,048-Event, 64 MiB callback ingress and bounded diagnostic counters.

There is no independent fixed Event-count limit. Small Events can therefore remain visible beyond
512 rows while they fit the 256 MiB budget. Internal storage capacity is derived from that byte
budget and the fixed minimum per-Event accounting overhead. When the byte bound is reached, the
oldest content is evicted so newer Events can continue to arrive. The Timeline reports the
resulting memory-window gap. These limits are process memory limits, not retention settings, and
the Viewer exposes no database capacity or TTL controls.

## Clear boundary

Clear shares the Session mutation gate with Event commits and import. It removes retained Events,
details, dispositions, diagnostics, and derived Performance state while preserving the listener,
pairing code, and active Device connections. An Event admitted after the boundary remains eligible
for the successor snapshot; stale work from before the boundary cannot repopulate cleared content.

## JSON export

Export freezes one immutable copy of the currently retained memory Session and writes the supported
schema-version-1 complete-Session JSON document. It includes only content still present in memory
and never claims earlier evicted history. The destination is selected explicitly and is not saved
as a Viewer preference.

The file is unencrypted. Device and connection names are pseudonyms, not redaction. Event content,
metadata, and peer-provided App fields can contain secrets or identifying data, and the destination
provider may synchronize or back up the file. Viewer presents this disclosure before export.

## JSON import

Import is allowed only when no App is active, disconnecting, or awaiting approval. The importer
requires the supported complete-Session schema and validates the file-size, 16-Device, 256-MiB
accounted-data, and byte-derived carrier limits before replacement. A Session is not rejected
merely because it contains more than 512 Events. Invalid, unsupported, cancelled, or oversized
input leaves the existing memory Session unchanged.

Imported Devices receive new local connection identifiers, remain offline, and cannot restore TLS
identity, installation authority, routing, queue state, or delivery claims. Temporary files used
while validating an import are removed on a best-effort basis after the operation and are not a
Session database. A process crash can leave an owner-only temporary copy for operating-system
temporary-directory cleanup.

## Failure behavior

Networking and the bounded memory Session do not depend on local persistence. User-visible errors
use fixed categories and do not include file paths, raw Event content, peer identifiers, or
operating-system diagnostics. Runtime shutdown clears the memory projection and derived values.
