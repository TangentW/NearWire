## ADDED Requirements

### Requirement: Core owns the closed ordered V1 performance metric inventory

NearWireCore SHALL expose through `NearWireInternal` SPI one `PerformanceMetricKey` inventory with
exactly these ordered raw values:

1. `process.cpuPercent`;
2. `process.memoryFootprintBytes`;
3. `display.estimatedFramesPerSecond`;
4. `display.maximumFramesPerSecond`;
5. `device.batteryLevel`;
6. `device.batteryState`;
7. `device.thermalState`;
8. `device.lowPowerModeEnabled`;
9. `device.gpuUtilization`;
10. `device.powerWatts`;
11. `device.temperatureCelsius`;
12. `transport.uplinkQueueDepth`;
13. `transport.droppedEventCount`;
14. `transport.uplinkBytesPerSecond`;
15. `transport.downlinkBytesPerSecond`; and
16. `transport.downlinkQueueDepth`.

The inventory SHALL expose stable process/display/device/transport ownership and whether a key is
numeric, categorical, or unavailable-only. NearWirePerformance and Viewer SHALL consume this one
SPI definition and SHALL NOT keep a second raw-string inventory. Moving the vocabulary SHALL change
no public API, encoded snapshot JSON, metric validation, collection side effect, or unknown-key
forward compatibility.

#### Scenario: SDK and Viewer enumerate metrics

- **WHEN** SDK unavailable projection and Viewer availability UI enumerate V1 keys
- **THEN** both receive the same 16 values, order, groups, and kinds from NearWireCore SPI
- **AND** neither module declares a duplicate metric-key enum or raw-string list

#### Scenario: Future unknown key is decoded

- **WHEN** a snapshot contains an unavailable key outside the closed V1 inventory
- **THEN** Core preserves the raw unavailable record while V1 consumers treat it as unknown raw-only data
- **AND** the closed inventory does not expand implicitly
