# Change: Raise default uplink throughput and enable recovery

## Why

NearWire currently defaults to no automatic recovery, a 100-Event/s App uplink ceiling, and a
20-Event/s Viewer request. A transient disconnect therefore requires explicit host action, and the
default negotiated uplink remains far below the desired 4,096 Events/s. The existing short queues
and 256-entry presentation ingress also provide little burst tolerance at that rate.

## What Changes

- Enable bounded automatic SDK recovery by default with 20 attempts, one-second initial delay, and
  a 30-second maximum exponential-backoff delay while retaining an explicit disabled policy.
- Raise the SDK default App-uplink maximum and Viewer default App-uplink request to 4,096 Events/s;
  keep all downlink defaults unchanged.
- Use a 0.25-second burst window for business-Event session buckets without changing the Core
  token-bucket default or the Viewer's 64/s system-message bucket.
- Expand the SDK offline queue to 10,000 Events/64 MiB and the Viewer per-device uplink queue to
  10,000 Events/64 MiB; keep the Viewer downlink queue at 5,000 Events/16 MiB.
- Expand Viewer presentation ingress to 2,048 Events while retaining its 64-MiB byte bound and the
  existing 256-MiB retained Session.
- Migrate the persisted legacy Viewer global default `20/10` to `4096/10` while preserving explicit
  global overrides, Bundle-ID policies, and nicknames.

## Scope

This change adjusts defaults and bounded high-throughput headroom. It does not promise lossless
offline retention at 4,096 Events/s, change the one-MiB content limit, increase downlink throughput,
alter the 256-MiB retained Session, introduce persistence, or implement a strict rolling-window rate
limiter.
