# API Inventory and Residual-Scope Audit

## Supported Distribution Inventory

The change does not modify `Package.swift` or `NearWire.podspec`. It therefore adds no product, target, pod subspec, runtime dependency, deployment-target change, entitlement, or privacy manifest. The repository contains no entitlement or privacy-manifest file in the affected distribution surface.

The canonical package gate compiled supported consumers in Swift 5 language mode for iOS 16 and macOS 13, dumped the `NearWire` SDK ABI, rejected implementation-only symbols, and compiled the CocoaPods same-module distribution. Both SwiftPM and CocoaPods negative consumers failed for the expected reason when attempting to name `SDKSessionAdmission`.

The only new callable Core surface used across package modules is marked SPI for the repository-owned transport implementation. It is not part of the supported SDK application API.

## Internal Boundary

`Scripts/check-session-admission-structure.rb` inspects all four admission implementation files and rejects any public admission declaration. The canonical structure and package gates both passed this audit. The SDK's existing supported facade and public model files are unchanged.

## Residual Scope

The structural audit proves the admission implementation contains none of the following:

- process lease claims;
- supported `NearWire` state mutation;
- SDK queue drain;
- Event envelope, payload, or batch transfer;
- raw `NWConnection` construction.

`testAdmissionDoesNotClaimLeaseOrMutateNearWireFacadeState` additionally exercises successful admission and verifies that it changes neither the process lease nor the supported facade state and transfers no Event. The implementation starts at protocol admission and hands off in the policy-negotiation phase; active Event pumping remains assigned to `sdk-active-event-pump`.

## Retention and Cleanup

The ownership audit and focused tests establish these bounds:

- callback ingress accounts pending and in-flight items under one combined event/byte limit;
- one actor turn drains at most eight ingress items and schedules at most one continuation drain;
- the external admitted and attachment handles share the sole relay retaining the permanent core, while the core does not retain that relay;
- channel callbacks route weakly through ingress and are never retargeted;
- terminal cleanup clears pairing and discovery identity, local and remote hello metadata, partial frame bytes, policy backlog and waiter, deadline tokens, ingress callbacks, and the live channel;
- stale cancellation, attempt, deadline, and pull tokens cannot revive or cancel later work.

The Round 3 architecture and security reviews independently re-audited this ownership graph and reported zero findings.
