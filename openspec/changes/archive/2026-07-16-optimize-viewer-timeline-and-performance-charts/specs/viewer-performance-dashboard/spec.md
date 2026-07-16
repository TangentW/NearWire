## MODIFIED Requirements

### Requirement: Aggregation remains globally bounded and deterministic

One result SHALL contain at most 512 aligned buckets as a defensive carrier limit, while the interactive dashboard SHALL request at most 120 aligned display buckets. Each result SHALL retain ten numeric accumulators per bucket, 128 detailed gaps, 128 invalid diagnostics, fixed summaries for the 16-metric inventory, six charts, 12,288 marks, and 64 accessible bucket summaries per chart. Prepared chart publication SHALL retain at most 1,200 measured points under a separate deterministic 157,696-byte publication-layer budget and SHALL NOT charge those transient presentation points to the completed-result cache ledger. Each numeric accumulator SHALL retain finite minimum, maximum, sum, count, first and last Viewer time, nonmeasurement counts, continuity, and one center-nearest contributing journal key. It SHALL NOT retain a complete raw-sample array.

At most four completed exact-key results SHALL be cached under the existing deterministic 16 MiB derived-state ledger; one completed result SHALL remain at most 8 MiB. Eviction SHALL occur before insertion. Limit exhaustion SHALL publish fixed guidance and SHALL NOT expose a partial result as complete.

#### Scenario: A long range contains many samples

- **WHEN** the selected memory slice contains more samples than the dashboard bucket count
- **THEN** values reduce into at most 120 aligned display buckets with average and min/max envelope
- **AND** raw sample count cannot create unbounded chart state

### Requirement: Projection refresh preserves stable SwiftUI presentation

Initial load, explicit Device or range replacement, empty state, Pause/Resume, and failure SHALL publish their visible states. Once a complete dashboard exists, ordinary refresh start and progress SHALL remain internal and SHALL NOT replace cards or charts with an intermediate loading branch, reset scrolling, recreate containers, or trigger implicit animation. A valid semantically changed successor SHALL publish exactly once; discarded or equivalent work SHALL publish nothing.

Projection, decoding, and chart-point preparation SHALL run off the MainActor under bounded cancellation and work rules. Chart preparation SHALL be linear in bucket count per metric, retain only bounded measured points, and precompute discontinuity segment identity. SwiftUI chart views SHALL consume prepared points and SHALL NOT rebuild aggregation or scan earlier buckets during body evaluation. At most one scan plus one dirty successor SHALL run, and current refresh SHALL publish at most once per main run-loop turn and ten times per second. Model changes SHALL not be published from within SwiftUI view updates.

Each measured chart bucket SHALL have an explicit visible point in addition to its average line and minimum/maximum envelope, so an isolated sample or a sample with equal minimum, average, and maximum remains visible. Stable chart and metric identity SHALL survive ordinary refresh.

#### Scenario: New performance Event arrives

- **WHEN** cards and charts are already visible
- **THEN** the prior dashboard remains continuously visible during off-main projection
- **AND** only changed prepared values publish without whole-window flashing or MainActor continuity rescans

#### Scenario: A chart contains one measured bucket

- **WHEN** one metric has exactly one measured bucket in the selected range
- **THEN** the chart displays a visible point for that measurement
- **AND** the absence of a line segment or envelope height does not make the chart appear empty
