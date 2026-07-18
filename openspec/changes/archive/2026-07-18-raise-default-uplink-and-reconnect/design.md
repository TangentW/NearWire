# Design

## Default recovery

`NearWireReconnectionPolicy.automatic` is a nonthrowing reviewed preset with 20 attempts, one-second
initial delay, and 30-second maximum delay. `NearWireConfiguration.default` and the public
initializer use this preset; `.disabled` remains available as an explicit opt-out. Existing
intent-bounded recovery, permanent-error classification, host-owned suspension, explicit
disconnect, and resume budget reset remain unchanged.

## Throughput and burst semantics

The App-local default uplink maximum and Viewer global requested uplink become 4,096 Events/s. The
effective session value remains the conservative minimum, so both defaults are required. Downlink
defaults remain 50 Events/s on the SDK and 10 Events/s on the Viewer.

Business-Event token buckets in the SDK and Viewer use an explicit 0.25-second burst duration. At
4,096 Events/s a fresh bucket therefore carries 1,024 tokens. Core's two-second default remains
unchanged for callers that do not opt into the session profile, and the Viewer system-message
bucket remains 64 Events/s with 128-token burst capacity.

This remains token-bucket average-rate control, not a strict rolling one-second counter.

## Queue and projection bounds

The SDK default offline queue becomes 10,000 Events/64 MiB while retaining the 4,259,840-byte
single-Event accounting bound and 60-second default TTL.

Viewer session queues become directional:

| Queue | Event count | Accounted bytes |
|---|---:|---:|
| App-to-Viewer uplink delivery | 10,000 | 64 MiB |
| Viewer-to-App downlink send | 5,000 | 16 MiB |

The existing 32-record service slice, 500-ms downlink batch interval, negotiated single-Event bound,
and Control reservations remain unchanged.

Viewer presentation ingress becomes 2,048 Events/64 MiB. Its byte bound remains independently
authoritative, so fewer than 2,048 larger Events may fit. Retained Session capacity remains 256 MiB
with 8,192 byte-derived slots. Sustained 4,096 Events/s can therefore rotate retained history
quickly; the new rate is a supported ceiling rather than a lossless-history promise.

## Preference migration

Viewer preferences advance from schema version 1 to version 2. Loading version 1:

- replaces only the exact legacy global pair `20/10` with the new `4096/10` default;
- preserves any other valid global pair;
- preserves valid Bundle-ID policies and route nicknames;
- applies the existing count, byte, timestamp, identifier, rate, and nickname repair.

Unknown versions and corrupt or over-limit data continue to fall back to a fresh bounded state.
Version 2 persists after load so migration is idempotent.

## Validation

- SDK configuration tests assert automatic recovery, exact retry values, 4,096 uplink, and expanded
  offline bounds while proving explicit disable remains available.
- Active-pump and Viewer session tests assert 1,024-token business burst capacity without changing
  the 128-token system-message burst.
- Viewer preference tests cover fresh defaults, exact legacy migration, custom-global preservation,
  Bundle-policy preservation, and idempotent version-2 reload.
- Viewer limit tests assert directional queue bounds and 2,048-entry/64-MiB projection ingress.
- Core/SDK/Viewer test suites, package builds, formatting, and strict OpenSpec validation provide
  regression evidence.
