# Render and Interaction Validation

- Rendered `ViewerPerformanceDashboardContent` from a real in-memory Performance Event publication at 1000 by 800 points.
- Confirmed current-value cards render measured values.
- Confirmed the Frame Rate chart contains visible measured point marks for both frame-rate series even when only one sample exists.
- Confirmed the view uses the published immutable chart projections rather than rebuilding them during SwiftUI body evaluation.
- Confirmed Timeline tail-follow behavior retains the existing viewport rule: new Events scroll only while the user remains at the bottom; the focused regression test passed.

Artifact: `populated-performance-chart.png`.
