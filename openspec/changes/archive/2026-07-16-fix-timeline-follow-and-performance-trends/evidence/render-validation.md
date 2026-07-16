# Render and Interaction Validation

- Inspected `continuous-performance-trends.png`, rendered from twenty Events paired across ten one-second sample positions and sparse display buckets.
- The final fixture uses ten one-second sample positions with two differing readings at each position, so ordinary buckets have a real minimum/average/maximum range.
- Confirmed Estimated and Maximum Frame Rate use continuous trend lines rather than isolated dots.
- Confirmed ordinary point markers are visually subordinate to the lines.
- Confirmed the chart retains axes, grid, legend, card context, and stable container layout.
- Confirmed the translucent Estimated Frame Rate min/max band is visibly distinct around the primary average line.
- The hosted Timeline regression exercised the actual macOS scroll container and confirmed a successor Event does not move a reading viewport that is 220 points above the bottom.
