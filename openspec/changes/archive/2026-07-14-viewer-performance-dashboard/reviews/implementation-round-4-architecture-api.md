# Implementation Review Round 4: Architecture and API

Date: 2026-07-14

## Verdict

Changes requested. Three actionable findings remained.

## Findings

### P1: Event traversal can restart before the combined replacement barrier

Explorer completed Store rematerialization by applying scope while Events remained active. That could
start Event traversal before the analysis coordinator had joined transition, Performance cleanup,
raw resolution, and catalog rematerialization.

### P1: First catalog pages are not identity authority

Recording and device survival was inferred from only the first 50 recording rows and 100 device rows.
A valid selected logical identity outside those pages could be treated as absent, and row reuse could
be evaluated without an exact full-catalog identity decision.

### P2: Snapshot failure leaves a nonterminal loading presentation

The rematerialization receipt completed after change-snapshot failure while recording state could
remain `loading`, leaving presentation without a terminal empty or failed state.

## Other observations

The constant-space reschedulable deadline worker was accepted. No files were modified by the
reviewer.
