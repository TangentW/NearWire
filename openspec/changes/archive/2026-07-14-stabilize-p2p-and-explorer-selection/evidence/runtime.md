# Runtime Evidence

Date: 2026-07-15

## Peer-to-Peer Route Diagnosis

An attached iPhone 17 Pro running iOS 26.5.1 established the NearWire TLS 1.3 session with ALPN `nearwire/1`. Viewer unified logging identified the data path as `awdl0`, including while the phone used cellular service for its ordinary Internet connection.

The peer-to-peer daemon reported the phone's peer presence immediately after connection setup and reported peer absence about 12 seconds after the connection became ready. Network.framework then changed the same connection path to `unsatisfied (No network route)` at 16.351 seconds. This ordering explains how one Event can arrive and another Event only a few seconds later can remain undelivered: the relevant timer starts at connection/discovery teardown, not at the preceding Event.

Source inspection found that the previous `ViewerDiscoveryCoordinator.finishSuccess` cancelled `NWBrowserDiscoveryDriver` immediately after returning the exact service endpoint. The working diagnosis is therefore premature release of the peer-to-peer-enabled discovery lifetime. The fix retains the started browser until the secure session terminates, but quiesces its callbacks and erases pairing-derived selection state immediately after the exact match. The transport keepalive configuration remains defense in depth and is not claimed as the root fix.

The iPhone is currently reachable only through wireless developer connectivity, which is insufficient for the harness to capture physical-device logs or drive a controlled retest. A post-fix physical-device repeated-send retest remains an explicit environmental limitation rather than a claimed result.

## Viewer Event Explorer Reproduction

The current Debug Viewer was launched after terminating stale Viewer and test processes. The previously failing sequence was exercised:

1. Select an empty recorded session.
2. Select another empty recorded session.
3. Select a recorded session containing 36 Events.
4. Select an Event and allow the durable inspector detail to load.

The timeline did not display `The requested bounded view is no longer valid`. The inspector showed the selected recorded Event with Metadata, Raw, and Tree content instead of `Event Detail Unavailable`.

The following narrow unified-log query was then run:

```sh
/usr/bin/log show --last 3m --style compact \
  --predicate 'process == "NearWire" AND (eventMessage CONTAINS[c] "Publishing changes" OR eventMessage CONTAINS[c] "bounded view" OR eventMessage CONTAINS[c] "Event Detail Unavailable")'
```

Result: only the log header was returned; there were no matching runtime warnings or detail failures.

## Root-Cause Correlation

Event pages, gap pages, details, and causality queries share a sliding query lease. A successful sibling operation advances the current idle deadline. Older Event and gap cursors were previously rejected because cursor validation required their issued deadline to exactly equal the newly refreshed deadline. The current implementation accepts an issued deadline that is no later than the current authoritative deadline while retaining query fingerprint, immutable snapshot, lease identity, direction, registry validation, and absolute lifetime checks.
