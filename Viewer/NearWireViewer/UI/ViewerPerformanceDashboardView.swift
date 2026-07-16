import Charts
import Combine
import Foundation
@_spi(NearWireInternal) import NearWireCore
import SwiftUI

enum ViewerPerformanceWindowLayout {
  static let minimumWidth: CGFloat = 800
  static let minimumHeight: CGFloat = 600
  static let defaultWidth: CGFloat = 1_100
  static let defaultHeight: CGFloat = 760
}

struct ViewerPerformanceMetricPresentation: Equatable, Sendable {
  let key: PerformanceMetricKey
  let title: String
  let unit: String
  let systemImage: String

  static let all: [ViewerPerformanceMetricPresentation] =
    PerformanceMetricKey.allCases.map(Self.make)

  static let currentCardKeys: [PerformanceMetricKey] = [
    .displayEstimatedFramesPerSecond,
    .displayMaximumFramesPerSecond,
    .processCPUPercent,
    .processMemoryFootprintBytes,
    .deviceBatteryLevel,
    .deviceBatteryState,
    .deviceThermalState,
    .deviceLowPowerModeEnabled,
    .transportUplinkQueueDepth,
    .transportDroppedEventCount,
    .transportUplinkBytesPerSecond,
    .transportDownlinkBytesPerSecond,
  ]

  static func descriptor(for key: PerformanceMetricKey) -> ViewerPerformanceMetricPresentation {
    guard let index = PerformanceMetricKey.allCases.firstIndex(of: key) else {
      preconditionFailure("Core performance metric inventory is incomplete")
    }
    return all[index]
  }

  static func groupTitle(_ group: PerformanceMetricGroup) -> String {
    switch group {
    case .process: return "Process"
    case .display: return "Display"
    case .device: return "Device"
    case .transport: return "Transport"
    }
  }

  private static func make(_ key: PerformanceMetricKey) -> ViewerPerformanceMetricPresentation {
    switch key {
    case .processCPUPercent:
      return value(key, "CPU", "%", "cpu")
    case .processMemoryFootprintBytes:
      return value(key, "Memory Footprint", "bytes", "memorychip")
    case .displayEstimatedFramesPerSecond:
      return value(key, "Estimated Frame Rate", "fps", "rectangle.on.rectangle")
    case .displayMaximumFramesPerSecond:
      return value(key, "Maximum Frame Rate", "fps", "speedometer")
    case .deviceBatteryLevel:
      return value(key, "Battery Level", "%", "battery.50percent")
    case .deviceBatteryState:
      return value(key, "Battery State", "state", "battery.100percent.bolt")
    case .deviceThermalState:
      return value(key, "Thermal State", "state", "thermometer.medium")
    case .deviceLowPowerModeEnabled:
      return value(key, "Low Power Mode", "state", "leaf")
    case .deviceGPUUtilization:
      return value(key, "GPU Utilization", "%", "square.stack.3d.up")
    case .devicePowerWatts:
      return value(key, "Power", "W", "bolt")
    case .deviceTemperatureCelsius:
      return value(key, "Temperature", "°C", "thermometer.high")
    case .transportUplinkQueueDepth:
      return value(key, "App → Viewer Queue", "events", "arrow.up.circle")
    case .transportDroppedEventCount:
      return value(key, "Dropped Events", "events", "exclamationmark.triangle")
    case .transportUplinkBytesPerSecond:
      return value(key, "App → Viewer Rate", "bytes/s", "arrow.up.right")
    case .transportDownlinkBytesPerSecond:
      return value(key, "Viewer → App Rate", "bytes/s", "arrow.down.left")
    case .transportDownlinkQueueDepth:
      return value(key, "Viewer → App Queue", "events", "arrow.down.circle")
    }
  }

  private static func value(
    _ key: PerformanceMetricKey,
    _ title: String,
    _ unit: String,
    _ systemImage: String
  ) -> ViewerPerformanceMetricPresentation {
    ViewerPerformanceMetricPresentation(
      key: key,
      title: title,
      unit: unit,
      systemImage: systemImage
    )
  }
}

struct ViewerPerformanceChartGroupPresentation: Equatable, Sendable {
  let title: String
  let unit: String
  let systemImage: String

  static func descriptor(
    for group: ViewerPerformanceChartGroupKind
  ) -> ViewerPerformanceChartGroupPresentation {
    switch group {
    case .display:
      return value("Frame Rate", "fps", "rectangle.on.rectangle")
    case .cpu:
      return value("CPU", "%", "cpu")
    case .memory:
      return value("Memory", "bytes", "memorychip")
    case .battery:
      return value("Battery", "%", "battery.50percent")
    case .throughput:
      return value("Throughput", "bytes/s", "arrow.up.arrow.down")
    case .queueAndDrops:
      return value("Queues and Drops", "events", "tray.full")
    }
  }

  private static func value(
    _ title: String,
    _ unit: String,
    _ systemImage: String
  ) -> ViewerPerformanceChartGroupPresentation {
    ViewerPerformanceChartGroupPresentation(
      title: title,
      unit: unit,
      systemImage: systemImage
    )
  }
}

enum ViewerPerformanceFormatting {
  static func cardValue(
    _ state: ViewerPerformanceCardState,
    for key: PerformanceMetricKey,
    locale: Locale = Locale(identifier: "en")
  ) -> String {
    switch state {
    case .measured(let measured):
      return measurement(measured, for: key, locale: locale)
    case .invalidSnapshot:
      return localized("Invalid snapshot", locale: locale)
    case .unavailable(let reason):
      return unavailable(reason, locale: locale)
    case .notCollected:
      return localized("Not collected", locale: locale)
    case .noRecentSample:
      return localized("No recent sample", locale: locale)
    }
  }

  static func availability(
    _ value: ViewerPerformanceAvailabilityPresentation,
    locale: Locale = Locale(identifier: "en")
  ) -> String {
    switch value {
    case .measured: return localized("Measured", locale: locale)
    case .invalidSnapshot: return localized("Invalid snapshot", locale: locale)
    case .unavailable(let reason): return unavailable(reason, locale: locale)
    case .notCollected: return localized("Not collected", locale: locale)
    }
  }

  static func availabilityDetail(
    _ counts: ViewerPerformanceAvailabilityCounts,
    locale: Locale = Locale(identifier: "en")
  ) -> String {
    var values: [String] = []
    append(counts.measured, "measured", locale: locale, to: &values)
    append(counts.invalid, "invalid", locale: locale, to: &values)
    append(counts.permissionDenied, "permission denied", locale: locale, to: &values)
    append(
      counts.temporarilyUnavailable,
      "temporarily unavailable",
      locale: locale,
      to: &values
    )
    append(counts.disabled, "disabled", locale: locale, to: &values)
    append(counts.unsupported, "unsupported", locale: locale, to: &values)
    append(counts.notCollected, "not collected", locale: locale, to: &values)
    return values.isEmpty ? localized("No samples in range", locale: locale) : values.joined(
      separator: " · ")
  }

  static func chartValue(_ value: Double, metric: ViewerPerformanceNumericMetric) -> Double {
    metric == .batteryFraction ? value * 100 : value
  }

  static func chartAxisValue(
    _ value: Double,
    group: ViewerPerformanceChartGroupKind,
    locale: Locale = Locale(identifier: "en")
  ) -> String {
    switch group {
    case .memory:
      return bytes(UInt64(max(0, value.rounded())), locale: locale)
    case .throughput:
      return "\(bytes(UInt64(max(0, value.rounded())), locale: locale))/s"
    case .battery, .cpu:
      return "\(decimal(value, locale: locale))%"
    case .display:
      return "\(decimal(value, locale: locale)) fps"
    case .queueAndDrops:
      return decimal(value, locale: locale)
    }
  }

  static func elapsedTime(
    _ seconds: Double,
    locale: Locale = Locale(identifier: "en")
  ) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0s" }
    if seconds < 60 { return "\(decimal(seconds, locale: locale))s" }
    return "\(decimal(seconds / 60, locale: locale))m"
  }

  private static func measurement(
    _ state: ViewerPerformanceMetricState,
    for key: PerformanceMetricKey,
    locale: Locale
  ) -> String {
    switch state {
    case .numeric(let value):
      switch key {
      case .processCPUPercent, .deviceGPUUtilization:
        return "\(decimal(value, locale: locale))%"
      case .deviceBatteryLevel:
        return "\(decimal(value * 100, locale: locale))%"
      case .displayEstimatedFramesPerSecond, .displayMaximumFramesPerSecond:
        return "\(decimal(value, locale: locale)) fps"
      case .devicePowerWatts:
        return "\(decimal(value, locale: locale)) W"
      case .deviceTemperatureCelsius:
        return "\(decimal(value, locale: locale)) °C"
      default:
        return decimal(value, locale: locale)
      }
    case .unsigned(let value):
      switch key {
      case .processMemoryFootprintBytes:
        return bytes(value, locale: locale)
      case .transportUplinkBytesPerSecond, .transportDownlinkBytesPerSecond:
        return "\(bytes(value, locale: locale))/s"
      default:
        return "\(value)"
      }
    case .batteryState(let value):
      switch value {
      case .unknown: return localized("Unknown", locale: locale)
      case .unplugged: return localized("Unplugged", locale: locale)
      case .charging: return localized("Charging", locale: locale)
      case .full: return localized("Full", locale: locale)
      }
    case .thermalState(let value):
      switch value {
      case .unknown: return localized("Unknown", locale: locale)
      case .nominal: return localized("Nominal", locale: locale)
      case .fair: return localized("Fair", locale: locale)
      case .serious: return localized("Serious", locale: locale)
      case .critical: return localized("Critical", locale: locale)
      }
    case .boolean(let value):
      return localized(value ? "On" : "Off", locale: locale)
    case .unavailable(let reason):
      return unavailable(reason, locale: locale)
    case .notCollected:
      return localized("Not collected", locale: locale)
    }
  }

  private static func unavailable(
    _ reason: UnavailablePerformanceMetricReason,
    locale: Locale
  ) -> String {
    switch reason {
    case .unsupported: return localized("Unsupported", locale: locale)
    case .disabled: return localized("Disabled", locale: locale)
    case .permissionDenied: return localized("Permission denied", locale: locale)
    case .temporarilyUnavailable: return localized("Temporarily unavailable", locale: locale)
    }
  }

  private static func decimal(_ value: Double, locale: Locale) -> String {
    let format = value.rounded() == value ? "%.0f" : "%.1f"
    return String(format: format, locale: locale, value)
  }

  private static func bytes(_ value: UInt64, locale: Locale) -> String {
    let units = ["B", "KiB", "MiB", "GiB", "TiB"]
    var amount = Double(value)
    var unitIndex = 0
    while amount >= 1_024, unitIndex < units.count - 1 {
      amount /= 1_024
      unitIndex += 1
    }
    return "\(decimal(amount, locale: locale)) \(units[unitIndex])"
  }

  private static func append(
    _ count: UInt64,
    _ label: String,
    locale: Locale,
    to values: inout [String]
  ) {
    guard count > 0 else { return }
    values.append(
      ViewerLocalization.format(
        "%llu %@",
        locale: locale,
        arguments: [count, localized(label, locale: locale)]
      ))
  }

  private static func localized(_ key: String, locale: Locale) -> String {
    ViewerLocalization.string(key, locale: locale)
  }
}

enum ViewerPerformanceAccessibilityFormatting {
  static func bucketIndices(
    for projection: ViewerPerformanceChartProjection
  ) -> [Int] {
    (try? ViewerPerformancePresentationBounds.accessibilityBucketIndices(
      bucketCount: projection.bucketCount
    )) ?? []
  }

  static func chartLabel(
    _ projection: ViewerPerformanceChartProjection,
    locale: Locale = Locale(identifier: "en")
  ) -> String {
    let descriptor = ViewerPerformanceChartGroupPresentation.descriptor(for: projection.group)
    return ViewerLocalization.format(
      "%@ performance chart. Aggregated average lines and min–max envelopes. %lld buckets.",
      locale: locale,
      arguments: [
        ViewerLocalization.string(descriptor.title, locale: locale), projection.bucketCount,
      ]
    )
  }

  static func bucketLabel(
    _ bucketIndex: Int,
    projection: ViewerPerformanceChartProjection,
    buckets: [ViewerPerformanceBucket],
    locale: Locale = Locale(identifier: "en")
  ) -> String? {
    guard buckets.count == projection.bucketCount,
      buckets.indices.contains(bucketIndex),
      buckets[bucketIndex].index == bucketIndex,
      let chartLower = projection.lowerMonotonicNanoseconds
    else { return nil }
    let bucket = buckets[bucketIndex]
    let span = ViewerLocalization.format(
      "Aggregated bucket %lld of %lld. Viewer time +%@ to +%@.",
      locale: locale,
      arguments: [
        bucketIndex + 1,
        projection.bucketCount,
        ViewerPerformanceFormatting.elapsedTime(
          elapsedSeconds(bucket.lowerMonotonicNanoseconds, from: chartLower), locale: locale),
        ViewerPerformanceFormatting.elapsedTime(
          elapsedSeconds(bucket.upperMonotonicNanoseconds, from: chartLower), locale: locale),
      ]
    )
    let series = projection.metrics.map { metric in
      seriesLabel(metric, bucket: bucket, group: projection.group, locale: locale)
    }
    return ([span] + series).joined(separator: " ")
  }

  private static func seriesLabel(
    _ metric: ViewerPerformanceNumericMetric,
    bucket: ViewerPerformanceBucket,
    group: ViewerPerformanceChartGroupKind,
    locale: Locale
  ) -> String {
    let descriptor = ViewerPerformanceMetricPresentation.descriptor(for: metric.key)
    let accumulator = bucket.numeric.accumulator(for: metric)
    let availability = bucket.availability.counts(for: metric.key)
    let continuity = ViewerLocalization.string(
      accumulator.isDiscontinuous ? "discontinuous" : "continuous", locale: locale)
    let availabilityState = ViewerPerformanceFormatting.availability(
      availability.presentation, locale: locale)
    let availabilityDetail = ViewerPerformanceFormatting.availabilityDetail(
      availability, locale: locale)
    let statistics: String
    if let minimum = accumulator.minimum,
      let average = accumulator.average,
      let maximum = accumulator.maximum
    {
      statistics = ViewerLocalization.format(
        "minimum %@, average %@, maximum %@, %llu samples",
        locale: locale,
        arguments: [
          value(minimum, metric: metric, group: group, locale: locale),
          value(average, metric: metric, group: group, locale: locale),
          value(maximum, metric: metric, group: group, locale: locale),
          accumulator.measurementCount,
        ]
      )
    } else {
      statistics = ViewerLocalization.string("no measured samples", locale: locale)
    }
    return ViewerLocalization.format(
      "%@, unit %@: %@; %@; availability %@, %@.",
      locale: locale,
      arguments: [
        ViewerLocalization.string(descriptor.title, locale: locale),
        ViewerLocalization.string(descriptor.unit, locale: locale),
        statistics,
        continuity,
        availabilityState,
        availabilityDetail,
      ]
    )
  }

  private static func value(
    _ value: Double,
    metric: ViewerPerformanceNumericMetric,
    group: ViewerPerformanceChartGroupKind,
    locale: Locale
  ) -> String {
    ViewerPerformanceFormatting.chartAxisValue(
      ViewerPerformanceFormatting.chartValue(value, metric: metric),
      group: group,
      locale: locale
    )
  }

  private static func elapsedSeconds(_ value: Int64, from lower: Int64) -> Double {
    guard value >= lower else { return 0 }
    return Double(UInt64(value) - UInt64(lower)) / 1_000_000_000
  }
}

private struct ViewerPerformanceWindowSignature: Equatable {
  let status: ViewerApplicationModel.Status
  let coordinatorIdentity: ObjectIdentifier?
}

@MainActor
private final class ViewerPerformanceWindowObserver: ObservableObject {
  @Published private(set) var revision: UInt64 = 0
  private var cancellables: Set<AnyCancellable> = []

  init(model: ViewerApplicationModel) {
    Publishers.CombineLatest(
      model.$status,
      model.$analysisCoordinator.map { $0.map(ObjectIdentifier.init) }
    )
    .map(ViewerPerformanceWindowSignature.init)
    .removeDuplicates()
    .dropFirst()
    .sink { [weak self] _ in self?.revision &+= 1 }
    .store(in: &cancellables)
  }
}

struct ViewerPerformanceWindowRootView: View {
  @Environment(\.openWindow) private var openWindow
  let model: ViewerApplicationModel
  @StateObject private var observer: ViewerPerformanceWindowObserver

  init(model: ViewerApplicationModel) {
    self.model = model
    _observer = StateObject(wrappedValue: ViewerPerformanceWindowObserver(model: model))
  }

  var body: some View {
    let _ = observer.revision
    Group {
      if let coordinator = model.analysisCoordinator {
        ViewerPerformanceWindowContent(
          coordinator: coordinator,
          showViewer: { openWindow(id: "main") }
        )
      } else {
        ViewerPerformanceUnavailableView(
          title: performanceUnavailableTitle,
          description: performanceUnavailableDescription,
          showViewer: { openWindow(id: "main") }
        )
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityIdentifier("nearwire.performance.window")
    .onAppear { model.analysisCoordinator?.showPerformance() }
    .onChange(of: observer.revision) { _ in
      model.analysisCoordinator?.showPerformance()
    }
    .onDisappear { model.analysisCoordinator?.showEvents() }
  }

  private var performanceUnavailableTitle: String {
    switch model.status {
    case .starting: return "Preparing Performance"
    case .failed: return "Performance Unavailable"
    case .stopped, .stopping: return "Viewer Runtime Not Running"
    case .listening: return "Preparing Performance"
    }
  }

  private var performanceUnavailableDescription: String {
    switch model.status {
    case .starting, .listening:
      return "The Performance workspace will appear when the Viewer runtime is ready."
    case .failed:
      return "Show the main Viewer window to retry the runtime. Performance will update automatically when it is ready."
    case .stopped, .stopping:
      return "Preparing the shared Viewer runtime."
    }
  }
}

struct ViewerPerformanceUnavailableView: View {
  static let showViewerAccessibilityIdentifier = "nearwire.performance.show-viewer"

  let title: String
  let description: String
  let showViewer: () -> Void

  func performShowViewer() {
    showViewer()
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        Label("Performance", systemImage: "chart.xyaxis.line")
          .font(.headline)
        Spacer()
        Button {
          performShowViewer()
        } label: {
          Label("Show Viewer", systemImage: "macwindow")
        }
        .help("Show the main Event window")
        .accessibilityLabel("Show main Viewer window")
        .accessibilityIdentifier(Self.showViewerAccessibilityIdentifier)
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 12)
      Divider()
      ViewerEmptyState(
        title: title,
        systemImage: "chart.xyaxis.line",
        description: description
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

struct ViewerPerformanceWindowContent: View {
  @Environment(\.locale) private var locale
  @ObservedObject var coordinator: ViewerAnalysisModeCoordinator
  let showViewer: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if coordinator.performanceDeviceID == nil {
        ViewerEmptyState(
          title: emptyStateTitle,
          systemImage: "iphone.gen3",
          description: emptyStateDescription
        )
        .accessibilityIdentifier("nearwire.performance.device-empty-state")
      } else {
        ViewerPerformanceDashboardView(
          coordinator: coordinator,
          openRawEvent: { bucketIndex, metric in
            coordinator.openRawEvent(bucketIndex: bucketIndex, metric: metric)
          }
        )
      }
    }
    .onChange(of: coordinator.eventRevealRevision) { _ in showViewer() }
  }

  private var header: some View {
    HStack(spacing: 14) {
      Label("Performance", systemImage: "chart.xyaxis.line")
        .font(.headline)
      Divider().frame(height: 24)
      VStack(alignment: .leading, spacing: 2) {
        Picker("Device", selection: deviceBinding) {
          Text(LocalizedStringKey(emptyDeviceTitle)).tag(Optional<UUID>.none)
          ForEach(coordinator.performanceDeviceOptions) { device in
            Text(deviceMenuTitle(device))
              .tag(Optional(device.id))
              .disabled(!device.isEligible)
              .accessibilityLabel(deviceAccessibilityLabel(device))
          }
        }
        .frame(width: 300)
        .disabled(coordinator.performanceDeviceOptions.isEmpty)
        .accessibilityLabel("Performance Device")
        .accessibilityIdentifier("nearwire.performance.device-picker")
        if let selectedDevice {
          Text(
            "\(selectedDevice.subtitle) · \(ViewerLocalization.string(selectedDevice.state.capitalized, locale: locale))"
          )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
          Text(LocalizedStringKey(deviceGuidance))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      Spacer()
      Button {
        showViewer()
      } label: {
        Label("Show Viewer", systemImage: "macwindow")
      }
      .help("Show the main Event window")
      .accessibilityLabel("Show main Viewer window")
      .accessibilityIdentifier("nearwire.performance.show-viewer")
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
  }

  private var deviceBinding: Binding<UUID?> {
    Binding(
      get: { coordinator.performanceDeviceID },
      set: { coordinator.setPerformanceDevice($0) }
    )
  }

  private var selectedDevice: ViewerPerformanceDeviceOption? {
    guard let selectedID = coordinator.performanceDeviceID else { return nil }
    return coordinator.performanceDeviceOptions.first { $0.id == selectedID }
  }

  private var emptyDeviceTitle: String {
    eligibleDevices.isEmpty ? "No Available Devices" : "Choose a Device"
  }

  private var deviceGuidance: String {
    eligibleDevices.isEmpty
      ? "Connect an App with an active performance target."
      : "Choose one Device for this window."
  }

  private var eligibleDevices: [ViewerPerformanceDeviceOption] {
    coordinator.performanceDeviceOptions.filter(\.isEligible)
  }

  private var emptyStateTitle: String {
    eligibleDevices.isEmpty ? "No Available Devices" : "Choose a Device"
  }

  private var emptyStateDescription: String {
    eligibleDevices.isEmpty
      ? "Connect an App that can provide performance data."
      : "Use the Device menu above to choose one exact App connection."
  }

  private func deviceMenuTitle(_ device: ViewerPerformanceDeviceOption) -> String {
    "\(device.title) — \(device.subtitle)"
  }

  private func deviceAccessibilityLabel(_ device: ViewerPerformanceDeviceOption) -> String {
    ViewerLocalization.format(
      "%@, %@, %@",
      locale: locale,
      arguments: [
        device.title,
        device.subtitle,
        ViewerLocalization.string(device.state.capitalized, locale: locale),
      ]
    )
  }
}

struct ViewerPerformanceDashboardView: View {
  @ObservedObject var coordinator: ViewerAnalysisModeCoordinator
  private let dashboard: ViewerPerformanceDashboardModel
  private let openRawEvent: (Int, ViewerPerformanceNumericMetric) -> Void

  init(
    coordinator: ViewerAnalysisModeCoordinator,
    openRawEvent: ((Int, ViewerPerformanceNumericMetric) -> Void)? = nil
  ) {
    self.coordinator = coordinator
    dashboard = coordinator.performanceController.model
    self.openRawEvent = openRawEvent ?? { [weak coordinator] bucketIndex, metric in
      coordinator?.openRawEvent(bucketIndex: bucketIndex, metric: metric)
    }
  }

  var body: some View {
    ViewerPerformanceDashboardContent(
      model: dashboard,
      guidance: coordinator.guidance,
      rangeKind: coordinator.performanceRangeKind,
      isPaused: coordinator.isPerformancePaused,
      setRange: { coordinator.setPerformanceRange($0) },
      setPaused: { coordinator.setPerformancePaused($0) },
      setCrosshair: {
        coordinator.performanceController.setCrosshair(
          viewerMonotonicNanoseconds: $0,
          chartGroup: $1,
          selectedMetric: $2
        )
      },
      clearCrosshair: { coordinator.performanceController.clearCrosshair() },
      openRawEvent: openRawEvent
    )
  }
}

@MainActor
struct ViewerPerformanceDashboardContent: View {
  @Environment(\.locale) private var locale
  @ObservedObject var model: ViewerPerformanceDashboardModel
  let guidance: ViewerAnalysisGuidance?
  let rangeKind: ViewerPerformanceRangeKind
  let isPaused: Bool
  let setRange: (ViewerPerformanceRangeKind) -> Void
  let setPaused: (Bool) -> Void
  let setCrosshair:
    (Int64, ViewerPerformanceChartGroupKind?, ViewerPerformanceNumericMetric?) -> Bool
  let clearCrosshair: () -> Void
  let openRawEvent: (Int, ViewerPerformanceNumericMetric) -> Void

  init(
    model: ViewerPerformanceDashboardModel,
    guidance: ViewerAnalysisGuidance?,
    rangeKind: ViewerPerformanceRangeKind? = nil,
    isPaused: Bool = false,
    setRange: @escaping (ViewerPerformanceRangeKind) -> Void = { _ in },
    setPaused: @escaping (Bool) -> Void = { _ in },
    setCrosshair:
      @escaping (
        Int64,
        ViewerPerformanceChartGroupKind?,
        ViewerPerformanceNumericMetric?
      ) -> Bool = { _, _, _ in false },
    clearCrosshair: @escaping () -> Void = {},
    openRawEvent: @escaping (Int, ViewerPerformanceNumericMetric) -> Void = { _, _ in }
  ) {
    self.model = model
    self.guidance = guidance
    self.rangeKind = rangeKind ?? model.rangeKind ?? .defaultKind
    self.isPaused = isPaused
    self.setRange = setRange
    self.setPaused = setPaused
    self.setCrosshair = setCrosshair
    self.clearCrosshair = clearCrosshair
    self.openRawEvent = openRawEvent
  }

  private let columns = [
    GridItem(.adaptive(minimum: 170, maximum: 280), spacing: 12, alignment: .top)
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        performanceControls
        performanceNotice
        currentSection
        chartsSection
        availabilitySection
      }
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityIdentifier("nearwire.performance.dashboard")
    .transaction { transaction in
      transaction.animation = nil
      transaction.disablesAnimations = true
    }
  }

  private var performanceControls: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        rangePicker
        Spacer()
        pauseButton
      }
      VStack(alignment: .trailing, spacing: 8) {
        rangePicker
        pauseButton
      }
    }
  }

  private var rangePicker: some View {
    Picker(
      "Range",
      selection: Binding(
        get: { rangeKind },
        set: { setRange($0) }
      )
    ) {
      ForEach(ViewerPerformanceRangeKind.allCases, id: \.self) { range in
        Text(LocalizedStringKey(rangeTitle(range))).tag(range)
      }
    }
    .pickerStyle(.segmented)
    .frame(maxWidth: 440)
    .accessibilityLabel("Performance range")
    .accessibilityIdentifier("nearwire.performance.range-picker")
  }

  private var pauseButton: some View {
    Button {
      setPaused(!isPaused)
    } label: {
      Label(
        isPaused ? "Resume" : "Pause",
        systemImage: isPaused ? "play.fill" : "pause.fill"
      )
    }
    .disabled(model.scope == nil)
    .accessibilityHint(
      isPaused
        ? "Resumes bounded performance refreshes."
        : "Freezes the current complete performance presentation."
    )
    .accessibilityIdentifier("nearwire.performance.pause")
  }

  @ViewBuilder
  private var performanceNotice: some View {
    if isPaused {
      notice(
        title: "Presentation paused",
        detail: "The current view is frozen. Resume to apply the latest bounded refresh.",
        systemImage: "pause.circle"
      )
    } else if model.coverage == .liveWindowOnly {
      notice(
        title: "Memory window only",
        detail: "Earlier Events are outside the retained memory window; the leading range remains disconnected.",
        systemImage: "dot.radiowaves.left.and.right"
      )
    }
  }

  private func notice(
    title: String,
    detail: String,
    systemImage: String
  ) -> some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(LocalizedStringKey(title)).font(.callout.weight(.semibold))
        Text(LocalizedStringKey(detail)).font(.caption).foregroundStyle(.secondary)
      }
    } icon: {
      Image(systemName: systemImage).foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
  }

  private func rangeTitle(_ range: ViewerPerformanceRangeKind) -> String {
    switch range {
    case .oneMinute: return "1 min"
    case .fiveMinutes: return "5 min"
    case .fifteenMinutes: return "15 min"
    case .currentSession: return "Session"
    }
  }

  private var currentSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text("Current").font(.title2.weight(.semibold))
        Spacer()
        Text(model.coverage == .liveWindowOnly ? "Memory window only" : "Latest sample")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let cards = model.cards {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
          ForEach(ViewerPerformanceMetricPresentation.currentCardKeys, id: \.self) { key in
            currentCard(key, cards: cards)
          }
        }
      } else {
        statusPanel
      }
    }
  }

  private func currentCard(
    _ key: PerformanceMetricKey,
    cards: ViewerPerformanceCardEvaluation
  ) -> some View {
    let descriptor = ViewerPerformanceMetricPresentation.descriptor(for: key)
    let value = ViewerPerformanceFormatting.cardValue(
      cards.state(for: key),
      for: key,
      locale: locale
    )
    return VStack(alignment: .leading, spacing: 9) {
      Label(LocalizedStringKey(descriptor.title), systemImage: descriptor.systemImage)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
      Text(value)
        .font(.system(.title3, design: .rounded, weight: .semibold))
        .lineLimit(2)
        .minimumScaleFactor(0.75)
      Text(LocalizedStringKey(descriptor.unit))
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      ViewerLocalization.format(
        "%@, %@, unit %@",
        locale: locale,
        arguments: [
          ViewerLocalization.string(descriptor.title, locale: locale),
          value,
          ViewerLocalization.string(descriptor.unit, locale: locale),
        ]
      )
    )
  }

  @ViewBuilder
  private var statusPanel: some View {
    if let guidance {
      performanceStatus(
        title: guidance.message,
        detail: "Choose one Device in the Performance window toolbar.",
        systemImage: "iphone.gen3"
      )
    } else {
      switch model.phase {
      case .loading:
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text("Loading performance data")
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .center)
      case .failed:
        performanceStatus(
          title: "Performance data unavailable",
          detail: "Refresh the current Session data or choose another App session.",
          systemImage: "exclamationmark.triangle"
        )
      case .empty:
        performanceStatus(
          title: "No performance Events in this range",
          detail: "Choose another fixed range or wait for the App to send a built-in snapshot.",
          systemImage: "chart.xyaxis.line"
        )
      case .idle, .ready:
        performanceStatus(
          title: "Waiting for performance data",
          detail: "NearWire will show the latest built-in performance Event here.",
          systemImage: "waveform.path.ecg"
        )
      }
    }
  }

  private func performanceStatus(
    title: String,
    detail: String,
    systemImage: String
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.title2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(LocalizedStringKey(title)).font(.headline)
        Text(LocalizedStringKey(detail)).font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
  }

  @ViewBuilder
  private var chartsSection: some View {
    let buckets = model.buckets
    let projections = model.chartProjections
    if !buckets.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Trends").font(.title2.weight(.semibold))
          Text("Average lines with a min–max envelope for each aggregated bucket")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if !projections.isEmpty {
          LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(projections) { projection in
              performanceChart(projection, buckets: buckets)
            }
          }
        } else {
          performanceStatus(
            title: "Chart data unavailable",
            detail: "The aggregated result did not satisfy the bounded chart contract.",
            systemImage: "chart.xyaxis.line"
          )
        }
      }
    }
  }

  private func performanceChart(
    _ projection: ViewerPerformanceChartProjection,
    buckets: [ViewerPerformanceBucket]
  ) -> some View {
    let descriptor = ViewerPerformanceChartGroupPresentation.descriptor(for: projection.group)
    return VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Label(LocalizedStringKey(descriptor.title), systemImage: descriptor.systemImage)
          .font(.headline)
        Spacer()
        Text(LocalizedStringKey(descriptor.unit))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Text(
        "Aggregated average · Min–max envelope · \(projection.bucketCount) buckets · \(projection.markCount) marks"
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
      if projection.hasMeasurements {
        Chart {
          ForEach(projection.series) { series in
            ForEach(series.points, id: \.bucketIndex) { point in
              let metric = series.metric
              let seriesTitle = ViewerPerformanceMetricPresentation.descriptor(
                for: metric.key
              ).title
              RectangleMark(
                  xStart: .value(
                    "Bucket start",
                    elapsedNanoseconds(
                      point.lowerMonotonicNanoseconds,
                      from: projection.lowerMonotonicNanoseconds
                    )
                  ),
                  xEnd: .value(
                    "Bucket end",
                    elapsedNanoseconds(
                      point.upperMonotonicNanoseconds,
                      from: projection.lowerMonotonicNanoseconds
                    )
                  ),
                  yStart: .value(
                    "Minimum",
                    ViewerPerformanceFormatting.chartValue(point.minimum, metric: metric)
                  ),
                  yEnd: .value(
                    "Maximum",
                    ViewerPerformanceFormatting.chartValue(point.maximum, metric: metric)
                  )
                )
              .foregroundStyle(by: .value("Metric", seriesTitle))
              .opacity(0.16)
              LineMark(
                  x: .value(
                    "Viewer time",
                    elapsedNanoseconds(
                      point.centerMonotonicNanoseconds,
                      from: projection.lowerMonotonicNanoseconds
                    )
                  ),
                  y: .value(
                    "Average",
                    ViewerPerformanceFormatting.chartValue(point.average, metric: metric)
                  ),
                  series: .value(
                    "Continuous segment",
                    "\(metric.rawValue):\(point.segmentStartBucketIndex)"
                  )
                )
              .foregroundStyle(by: .value("Metric", seriesTitle))
              .lineStyle(seriesLineStyle(metric))
              PointMark(
                  x: .value(
                    "Viewer time",
                    elapsedNanoseconds(
                      point.centerMonotonicNanoseconds,
                      from: projection.lowerMonotonicNanoseconds
                    )
                  ),
                  y: .value(
                    "Average",
                    ViewerPerformanceFormatting.chartValue(point.average, metric: metric)
                  )
                )
              .foregroundStyle(by: .value("Metric", seriesTitle))
              .symbolSize(20)
            }
          }
          if let crosshair = model.crosshair {
            RuleMark(
              x: .value(
                "Selected Viewer time",
                elapsedNanoseconds(
                  crosshair.viewerMonotonicNanoseconds,
                  from: projection.lowerMonotonicNanoseconds
                )
              )
            )
            .foregroundStyle(.primary)
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
          }
        }
        .chartXScale(domain: chartDomain(projection))
        .chartXAxis {
          AxisMarks(values: .automatic(desiredCount: 5)) { value in
            AxisGridLine()
            AxisTick()
            AxisValueLabel {
              if let seconds = value.as(Double.self) {
                Text(ViewerPerformanceFormatting.elapsedTime(seconds, locale: locale))
              }
            }
          }
        }
        .chartYAxis {
          AxisMarks(position: .leading) { value in
            AxisGridLine()
            AxisTick()
            AxisValueLabel {
              if let number = value.as(Double.self) {
                Text(
                  ViewerPerformanceFormatting.chartAxisValue(
                    number,
                    group: projection.group,
                    locale: locale
                  )
                )
              }
            }
          }
        }
        .chartLegend(position: .top, alignment: .leading, spacing: 8)
        .chartOverlay { proxy in
          GeometryReader { geometry in
            Rectangle()
              .fill(.clear)
              .contentShape(Rectangle())
              .onContinuousHover { phase in
                if case .active(let location) = phase {
                  updateCrosshair(
                    at: location,
                    proxy: proxy,
                    geometry: geometry,
                    projection: projection,
                    buckets: buckets
                  )
                }
              }
              .gesture(
                DragGesture(minimumDistance: 0)
                  .onChanged { value in
                    updateCrosshair(
                      at: value.location,
                      proxy: proxy,
                      geometry: geometry,
                      projection: projection,
                      buckets: buckets
                    )
                  }
              )
              .focusable()
              .onMoveCommand { direction in
                moveCrosshair(direction, projection: projection, buckets: buckets)
              }
          }
        }
        .frame(minHeight: 210, idealHeight: 230)
        .accessibilityRepresentation {
          VStack(alignment: .leading, spacing: 0) {
            Text(
              ViewerPerformanceAccessibilityFormatting.chartLabel(
                projection,
                locale: locale
              )
            )
            ForEach(
              ViewerPerformanceAccessibilityFormatting.bucketIndices(for: projection),
              id: \.self
            ) { bucketIndex in
              if let label = ViewerPerformanceAccessibilityFormatting.bucketLabel(
                bucketIndex,
                projection: projection,
                buckets: buckets,
                locale: locale
              ) {
                Text(label)
              }
            }
          }
        }
        if model.crosshair?.chartGroup == projection.group {
          aggregateTooltip(projection, buckets: buckets)
        }
      } else {
        Text("No measured samples in this range")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
      }
    }
    .padding(14)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    }
    .accessibilityIdentifier("nearwire.performance.chart.\(projection.group)")
  }

  private func seriesLineStyle(_ metric: ViewerPerformanceNumericMetric) -> StrokeStyle {
    switch metric.rawValue % 3 {
    case 1:
      return StrokeStyle(lineWidth: 1.6, dash: [7, 3])
    case 2:
      return StrokeStyle(lineWidth: 1.6, dash: [2, 3])
    default:
      return StrokeStyle(lineWidth: 1.6)
    }
  }

  private func elapsedNanoseconds(_ value: Int64, from lower: Int64?) -> Double {
    guard let lower, value >= lower else { return 0 }
    return Double(UInt64(value) - UInt64(lower)) / 1_000_000_000
  }

  private func updateCrosshair(
    at location: CGPoint,
    proxy: ChartProxy,
    geometry: GeometryProxy,
    projection: ViewerPerformanceChartProjection,
    buckets: [ViewerPerformanceBucket]
  ) {
    let plotFrame = geometry[proxy.plotAreaFrame]
    guard plotFrame.contains(location) else { return }
    let plotX = location.x - plotFrame.minX
    let plotY = location.y - plotFrame.minY
    guard let elapsedSeconds: Double = proxy.value(atX: plotX),
      let monotonic = monotonicNanoseconds(
        elapsedSeconds: elapsedSeconds,
        projection: projection
      ),
      let bucketIndex = buckets.firstIndex(where: {
        monotonic >= $0.lowerMonotonicNanoseconds
          && monotonic <= $0.upperMonotonicNanoseconds
      })
    else { return }
    let displayValue: Double? = proxy.value(atY: plotY)
    let metric = nearestMetric(
      displayValue: displayValue,
      bucketIndex: bucketIndex,
      projection: projection,
      buckets: buckets
    )
    _ = setCrosshair(monotonic, projection.group, metric)
  }

  private func monotonicNanoseconds(
    elapsedSeconds: Double,
    projection: ViewerPerformanceChartProjection
  ) -> Int64? {
    guard elapsedSeconds.isFinite, elapsedSeconds >= 0,
      let lower = projection.lowerMonotonicNanoseconds,
      let upper = projection.upperMonotonicNanoseconds,
      lower >= 0, upper >= lower
    else { return nil }
    let available = UInt64(upper) - UInt64(lower)
    let requested = min(
      Double(available),
      max(0, (elapsedSeconds * 1_000_000_000).rounded())
    )
    let offset = UInt64(requested)
    return Int64(UInt64(lower) + offset)
  }

  private func nearestMetric(
    displayValue: Double?,
    bucketIndex: Int,
    projection: ViewerPerformanceChartProjection,
    buckets: [ViewerPerformanceBucket]
  ) -> ViewerPerformanceNumericMetric? {
    guard buckets.indices.contains(bucketIndex) else { return nil }
    let candidates = projection.metrics.compactMap {
      metric -> (ViewerPerformanceNumericMetric, Double)? in
      guard
        let average = buckets[bucketIndex].numeric.accumulator(for: metric).average
      else { return nil }
      return (metric, ViewerPerformanceFormatting.chartValue(average, metric: metric))
    }
    guard let displayValue else { return candidates.first?.0 }
    return candidates.min {
      let lhsDistance = abs($0.1 - displayValue)
      let rhsDistance = abs($1.1 - displayValue)
      if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
      return $0.0.rawValue < $1.0.rawValue
    }?.0
  }

  private func moveCrosshair(
    _ direction: MoveCommandDirection,
    projection: ViewerPerformanceChartProjection,
    buckets: [ViewerPerformanceBucket]
  ) {
    let keyboardDirection: ViewerPerformanceKeyboardDirection
    switch direction {
    case .left: keyboardDirection = .left
    case .right: keyboardDirection = .right
    case .up: keyboardDirection = .up
    case .down: keyboardDirection = .down
    default:
      return
    }
    guard
      let selection = ViewerPerformanceKeyboardNavigation.selection(
        direction: keyboardDirection,
        current: model.crosshair,
        projection: projection,
        buckets: buckets
      )
    else { return }
    _ = setCrosshair(
      selection.viewerMonotonicNanoseconds,
      selection.chartGroup,
      selection.selectedMetric
    )
  }

  @ViewBuilder
  private func aggregateTooltip(
    _ projection: ViewerPerformanceChartProjection,
    buckets: [ViewerPerformanceBucket]
  ) -> some View {
    if let crosshair = model.crosshair,
      buckets.indices.contains(crosshair.bucketIndex)
    {
      let bucket = buckets[crosshair.bucketIndex]
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Selected aggregate").font(.callout.weight(.semibold))
            Text(
              ViewerLocalization.format(
                "Viewer +%@ – +%@",
                locale: locale,
                arguments: [
                  ViewerPerformanceFormatting.elapsedTime(
                    elapsedNanoseconds(
                      bucket.lowerMonotonicNanoseconds,
                      from: projection.lowerMonotonicNanoseconds
                    ),
                    locale: locale
                  ),
                  ViewerPerformanceFormatting.elapsedTime(
                    elapsedNanoseconds(
                      bucket.upperMonotonicNanoseconds,
                      from: projection.lowerMonotonicNanoseconds
                    ),
                    locale: locale
                  ),
                ]
              )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Clear") { clearCrosshair() }
            .buttonStyle(.borderless)
        }
        if projection.metrics.count > 1 {
          Menu {
            ForEach(projection.metrics, id: \.self) { metric in
              Button(
                LocalizedStringKey(
                  ViewerPerformanceMetricPresentation.descriptor(for: metric.key).title
                )
              ) {
                _ = setCrosshair(
                  crosshair.viewerMonotonicNanoseconds,
                  projection.group,
                  metric
                )
              }
            }
          } label: {
            Label(
              LocalizedStringKey(selectedMetricTitle(crosshair.selectedMetric)),
              systemImage: "line.3.horizontal.decrease.circle"
            )
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
        }
        ForEach(projection.metrics, id: \.self) { metric in
          tooltipMetricRow(
            metric,
            bucket: bucket,
            group: projection.group,
            isSelected: crosshair.selectedMetric == metric
          )
        }
        HStack {
          Spacer()
          Button {
            if let metric = crosshair.selectedMetric {
              openRawEvent(bucket.index, metric)
            }
          } label: {
            Label("Open Raw Event", systemImage: "arrow.right.circle")
          }
          .disabled(
            crosshair.selectedMetric.flatMap {
              bucket.numeric.accumulator(for: $0).representative
            } == nil
          )
          .accessibilityIdentifier("nearwire.performance.open-raw-event")
        }
      }
      .padding(12)
      .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      }
      .accessibilityIdentifier("nearwire.performance.tooltip")
    }
  }

  private func tooltipMetricRow(
    _ metric: ViewerPerformanceNumericMetric,
    bucket: ViewerPerformanceBucket,
    group: ViewerPerformanceChartGroupKind,
    isSelected: Bool
  ) -> some View {
    let descriptor = ViewerPerformanceMetricPresentation.descriptor(for: metric.key)
    let accumulator = bucket.numeric.accumulator(for: metric)
    let availability = bucket.availability.counts(for: metric.key)
    return HStack(alignment: .top, spacing: 8) {
      Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(isSelected ? .primary : .secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(LocalizedStringKey(descriptor.title)).font(.caption.weight(.semibold))
        if let minimum = accumulator.minimum,
          let average = accumulator.average,
          let maximum = accumulator.maximum
        {
          Text(
            "Min \(tooltipValue(minimum, metric: metric, group: group)) · Avg \(tooltipValue(average, metric: metric, group: group)) · Max \(tooltipValue(maximum, metric: metric, group: group)) · \(accumulator.measurementCount) samples"
          )
          .font(.caption)
        } else {
          Text("No measured samples").font(.caption)
        }
        Text(
          "\(ViewerLocalization.string(accumulator.isDiscontinuous ? "Discontinuous" : "Continuous", locale: locale)) · \(ViewerPerformanceFormatting.availability(availability.presentation, locale: locale)) · \(nonmeasurementSummary(accumulator.nonmeasurements))"
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func selectedMetricTitle(_ metric: ViewerPerformanceNumericMetric?) -> String {
    guard let metric else { return "No measured series" }
    return ViewerPerformanceMetricPresentation.descriptor(for: metric.key).title
  }

  private func tooltipValue(
    _ value: Double,
    metric: ViewerPerformanceNumericMetric,
    group: ViewerPerformanceChartGroupKind
  ) -> String {
    ViewerPerformanceFormatting.chartAxisValue(
      ViewerPerformanceFormatting.chartValue(value, metric: metric),
      group: group,
      locale: locale
    )
  }

  private func nonmeasurementSummary(
    _ counts: ViewerPerformanceNonmeasurementCounts
  ) -> String {
    var values: [String] = []
    func append(_ value: UInt64, _ title: String) {
      guard value > 0 else { return }
      values.append(
        ViewerLocalization.format(
          "%llu %@",
          locale: locale,
          arguments: [value, ViewerLocalization.string(title, locale: locale)]
        )
      )
    }
    append(counts.invalid, "invalid")
    append(counts.permissionDenied, "permission denied")
    append(counts.temporarilyUnavailable, "temporarily unavailable")
    append(counts.disabled, "disabled")
    append(counts.unsupported, "unsupported")
    append(counts.notCollected, "not collected")
    return values.isEmpty
      ? ViewerLocalization.string("No nonmeasurements", locale: locale)
      : values.joined(separator: " · ")
  }

  private func chartDomain(_ projection: ViewerPerformanceChartProjection) -> ClosedRange<Double> {
    let upper = elapsedNanoseconds(
      projection.upperMonotonicNanoseconds ?? 0,
      from: projection.lowerMonotonicNanoseconds
    )
    return 0...max(upper, 0.000_000_001)
  }

  private var availabilitySection: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Availability").font(.title2.weight(.semibold))
        Text("All 16 built-in metrics in the selected range")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      ViewThatFits(in: .horizontal) {
        availabilityTable
        availabilityList
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
  }

  private var availabilityTable: some View {
    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
      GridRow {
        Text("Metric").font(.caption.weight(.semibold))
        Text("Unit").font(.caption.weight(.semibold))
        Text("State").font(.caption.weight(.semibold))
        Text("Samples").font(.caption.weight(.semibold))
      }
      Divider().gridCellColumns(4)
      ForEach(PerformanceMetricGroup.allCases, id: \.self) { group in
        Text(LocalizedStringKey(ViewerPerformanceMetricPresentation.groupTitle(group)))
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .gridCellColumns(4)
          .padding(.top, 4)
        ForEach(group.keys, id: \.self) { key in
          availabilityTableRow(key)
        }
      }
    }
  }

  private var availabilityList: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(PerformanceMetricGroup.allCases, id: \.self) { group in
        Text(LocalizedStringKey(ViewerPerformanceMetricPresentation.groupTitle(group)))
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        ForEach(group.keys, id: \.self) { key in
          availabilityListRow(key)
        }
      }
    }
  }

  private func availabilityTableRow(_ key: PerformanceMetricKey) -> some View {
    let content = availabilityContent(key)
    return GridRow {
      Label(LocalizedStringKey(content.descriptor.title), systemImage: content.descriptor.systemImage)
      Text(LocalizedStringKey(content.descriptor.unit)).foregroundStyle(.secondary)
      Text(LocalizedStringKey(content.state))
      Text(LocalizedStringKey(content.detail)).font(.caption).foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(content.accessibilityLabel)
  }

  private func availabilityListRow(_ key: PerformanceMetricKey) -> some View {
    let content = availabilityContent(key)
    return VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Label(LocalizedStringKey(content.descriptor.title), systemImage: content.descriptor.systemImage)
        Spacer(minLength: 12)
        Text(LocalizedStringKey(content.descriptor.unit))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Text(LocalizedStringKey(content.state)).font(.callout.weight(.medium))
      Text(LocalizedStringKey(content.detail)).font(.caption).foregroundStyle(.secondary)
    }
    .padding(.vertical, 3)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(content.accessibilityLabel)
  }

  private func availabilityContent(_ key: PerformanceMetricKey) -> AvailabilityContent {
    let descriptor = ViewerPerformanceMetricPresentation.descriptor(for: key)
    let entry = model.availability.first { $0.key == key }
    let state =
      entry.map { ViewerPerformanceFormatting.availability($0.presentation, locale: locale) }
      ?? ViewerLocalization.string("Waiting for data", locale: locale)
    let detail =
      entry.map { ViewerPerformanceFormatting.availabilityDetail($0.counts, locale: locale) }
      ?? ViewerLocalization.string("No completed range", locale: locale)
    return AvailabilityContent(
      descriptor: descriptor,
      state: state,
      detail: detail,
      accessibilityLabel: ViewerLocalization.format(
        "%@, unit %@, %@, %@",
        locale: locale,
        arguments: [
          ViewerLocalization.string(descriptor.title, locale: locale),
          ViewerLocalization.string(descriptor.unit, locale: locale),
          state,
          detail,
        ]
      )
    )
  }

  private struct AvailabilityContent {
    let descriptor: ViewerPerformanceMetricPresentation
    let state: String
    let detail: String
    let accessibilityLabel: String
  }
}
