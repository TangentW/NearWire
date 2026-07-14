# Spec-to-Evidence Audit

Date: 2026-07-15

## `sdk-bonjour-discovery`

The discovery coordinator returns one exact endpoint without cancelling the peer-to-peer browser, erases its expected instance name, and asks the driver to quiesce all callbacks. Session admission transfers that silent discovery operation into the transport core, whose first terminal transition releases it exactly once. Focused discovery and admission tests cover exact match, late callbacks, cancellation races, setup and handshake failure, attachment failure, and active-session teardown. The strict Swift package run covers the same production modules under complete concurrency checking.

## `secure-network-parameters`

The shared App and Viewer parameter constructor fixes TCP keepalive idle, interval, and probe count together with the existing TLS 1.3, ALPN, and peer-to-peer policy. Parameter tests inspect both roles. The strict Swift package run and iOS Demo build cover the shared implementation.

## `viewer-event-explorer-control`

Store query tests cover backward cursor boundaries and same-lease deadline refresh. Controller and coordinator tests cover release/loading suppression, pause-time ownership, successor detail loading, single-flight pagination, stale failure removal, retained selection, and deferred SwiftUI selection invalidation. The full Viewer test result contains 412 tests with 2 expected skips and 0 failures. Runtime inspection separately confirmed that the bounded-view warning, unavailable detail, and synchronous publication warning were absent in the exercised recorded-session flow.

## Environmental Limitation

Captured pre-fix logs establish the AWDL peer-absence and route-loss sequence and correlate it with premature browser cancellation. The physical iPhone is no longer available over USB for an automated post-fix repeated-send run. No post-fix physical-device success is claimed; this remains the final manual acceptance check after delivery.

## Audit Result

Every modified requirement has source coverage and automated evidence proportionate to its scope. The only unavailable evidence is the explicitly conditional post-fix physical-device run described above.
