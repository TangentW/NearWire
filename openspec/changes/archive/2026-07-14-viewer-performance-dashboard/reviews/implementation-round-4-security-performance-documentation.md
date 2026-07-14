# Implementation Review Round 4: Security, Performance, and Documentation

Date: 2026-07-14

## Verdict

Changes requested. Six actionable findings remained.

## Findings

### P1: Missing selected device can broaden scope to all devices

Removing a selected logical device that was absent from the replacement page made empty selection
mean all devices. A missing device must remain an explicit no-match scope.

### P1: First pages cannot authorize logical identity survival

Page-bounded recording/device lookup could misclassify an identity outside the resident window.

### P1: Scope applies before the combined replacement barrier

Explorer could start Event work before the analysis coordinator joined every replacement owner.

### P1: Predecessor operation authority can cross Store generations

Prepared delete, export, and destination results were not synchronously revoked, while committed
export completion required a narrower preservation rule.

### P2: Snapshot failure leaves loading state

Failure completed rematerialization without guaranteed terminal catalog presentation.

### P2: Dirty Store-change signal can be lost during rematerialization

The change-snapshot handler cleared the dirty bit before replacement catalogs completed, so a Store
change arriving during that window might not receive one successor refresh.

## Other observations

Exact lookup should remain bounded and use existing indexed logical identities. No new privacy sink
or third-party dependency was found. No files were modified by the reviewer.
