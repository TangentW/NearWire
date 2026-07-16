## MODIFIED Requirements

### Requirement: Projection refresh preserves stable SwiftUI presentation

Initial load, explicit Device or range replacement, empty state, Pause/Resume, and failure SHALL publish their visible states. Once a complete dashboard exists, ordinary refresh start and progress SHALL remain internal and SHALL NOT replace cards or charts with an intermediate loading branch, reset scrolling, recreate containers, or trigger implicit animation. A valid semantically changed successor SHALL publish exactly once; discarded or equivalent work SHALL publish nothing.

Projection, decoding, and chart-point preparation SHALL run off the MainActor under bounded cancellation and work rules. Chart preparation SHALL be linear in bucket count per metric, retain only bounded measured points, and precompute discontinuity segment identity. SwiftUI chart views SHALL consume prepared points and SHALL NOT rebuild aggregation or scan earlier buckets during body evaluation. At most one scan plus one dirty successor SHALL run, and current refresh SHALL publish at most once per main run-loop turn and ten times per second. Model changes SHALL not be published from within SwiftUI view updates.

An empty aggregation bucket SHALL NOT by itself split a measured series. Prepared points SHALL remain connected across empty display buckets unless the continuity tracker, availability transition, or gap projection explicitly marks a break. The chart SHALL present the minimum/maximum envelope as a translucent continuous band and the average as the primary trend line. Point markers SHALL remain subordinate for multi-point series and SHALL become prominent when a series contains only one measured point. Stable chart and metric identity SHALL survive ordinary refresh.

#### Scenario: New performance Event arrives

- **WHEN** cards and charts are already visible
- **THEN** the prior dashboard remains continuously visible during off-main projection
- **AND** only changed prepared values publish without whole-window flashing or MainActor continuity rescans

#### Scenario: Periodic samples occupy nonadjacent display buckets

- **WHEN** valid periodic measurements have empty aggregation buckets between them and no explicit discontinuity applies
- **THEN** the dashboard connects their average values into one readable trend and shades the min/max envelope
- **AND** the empty display buckets do not reduce the chart to isolated dots

#### Scenario: A chart contains one measured bucket

- **WHEN** one metric has exactly one measured bucket in the selected range
- **THEN** the chart displays a prominent visible point for that measurement
- **AND** the absence of a line segment or envelope height does not make the chart appear empty
