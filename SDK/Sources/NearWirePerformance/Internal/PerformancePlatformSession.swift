import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
#endif

protocol PerformancePlatformSession: Sendable {
  func activate() async
  func sample() async -> (display: PerformanceDisplayReading?, device: PerformanceDeviceReading?)
  func stop() async
}

struct DisabledPerformancePlatformSession: PerformancePlatformSession {
  func activate() async {}

  func sample() async -> (
    display: PerformanceDisplayReading?,
    device: PerformanceDeviceReading?
  ) {
    (display: nil, device: nil)
  }

  func stop() async {}
}

#if os(iOS)
  import QuartzCore
  import UIKit

  final class LivePerformancePlatformSession: PerformancePlatformSession, @unchecked Sendable {
    @MainActor
    private final class DisplayTarget: NSObject {
      private var accumulator = PerformanceDisplayAccumulator()

      @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {
        accumulator.record(timestamp: displayLink.timestamp)
      }

      func consumeEstimatedFramesPerSecond() -> Double? {
        accumulator.consumeEstimatedFramesPerSecond()
      }

      func reset() {
        accumulator.reset()
      }
    }

    @MainActor
    private final class Storage {
      private let configuration: NearWirePerformanceConfiguration
      private let displayTarget: DisplayTarget?
      private var displayLink: CADisplayLink?
      private var batteryClaim: PerformanceBatteryMonitoringClaim?
      private var didStop = false

      init(
        configuration: NearWirePerformanceConfiguration,
        attempt: PerformanceStartAttempt
      ) {
        self.configuration = configuration
        if configuration.displayMetricsEnabled,
          let resources = attempt.performAcquisition({
            let target = DisplayTarget()
            let link = CADisplayLink(
              target: target,
              selector: #selector(DisplayTarget.displayLinkDidFire(_:))
            )
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            return (target, link)
          })
        {
          displayTarget = resources.0
          displayLink = resources.1
        } else {
          displayTarget = nil
          displayLink = nil
        }

        if configuration.deviceMetricsEnabled, configuration.managesBatteryMonitoring,
          let claim = attempt.performAcquisition({
            PerformanceBatteryMonitoringRegistry.claim()
          })
        {
          batteryClaim = claim
        }
      }

      func activate() {
        displayTarget?.reset()
        displayLink?.isPaused = false
      }

      func sample() -> (
        display: PerformanceDisplayReading?,
        device: PerformanceDeviceReading?
      ) {
        let display =
          configuration.displayMetricsEnabled
          ? PerformanceDisplayReading(
            estimatedFramesPerSecond: displayTarget?.consumeEstimatedFramesPerSecond()
          ) : nil

        let device: PerformanceDeviceReading?
        if configuration.deviceMetricsEnabled {
          let batteryIsAvailable: Bool
          if configuration.managesBatteryMonitoring {
            batteryIsAvailable = PerformanceBatteryMonitoringRegistry.observeEnabled()
          } else {
            batteryIsAvailable = UIDevice.current.isBatteryMonitoringEnabled
          }

          let level = UIDevice.current.batteryLevel
          device = PerformanceDeviceReading(
            batteryLevel: batteryIsAvailable && level.isFinite && (0...1).contains(level)
              ? Double(level) : nil,
            batteryState: batteryIsAvailable
              ? Self.batteryState(UIDevice.current.batteryState) : nil,
            thermalState: Self.thermalState(ProcessInfo.processInfo.thermalState),
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
          )
        } else {
          device = nil
        }
        return (display, device)
      }

      func stop() {
        guard !didStop else { return }
        didStop = true
        displayLink?.invalidate()
        displayLink = nil
        displayTarget?.reset()
        batteryClaim?.release()
        batteryClaim = nil
      }

      private static func batteryState(_ state: UIDevice.BatteryState) -> BatteryState {
        switch state {
        case .unplugged:
          return .unplugged
        case .charging:
          return .charging
        case .full:
          return .full
        case .unknown:
          return .unknown
        @unknown default:
          return .unknown
        }
      }

      private static func thermalState(_ state: ProcessInfo.ThermalState) -> ThermalState {
        switch state {
        case .nominal:
          return .nominal
        case .fair:
          return .fair
        case .serious:
          return .serious
        case .critical:
          return .critical
        @unknown default:
          return .unknown
        }
      }
    }

    private let storage: Storage

    private init(storage: Storage) {
      self.storage = storage
    }

    static func make(
      configuration: NearWirePerformanceConfiguration,
      attempt: PerformanceStartAttempt
    ) async -> LivePerformancePlatformSession {
      await LivePerformancePlatformSession(
        storage: Storage(configuration: configuration, attempt: attempt)
      )
    }

    func activate() async {
      await storage.activate()
    }

    func sample() async -> (
      display: PerformanceDisplayReading?,
      device: PerformanceDeviceReading?
    ) {
      await storage.sample()
    }

    func stop() async {
      await storage.stop()
    }
  }

  @MainActor
  private final class PerformanceBatteryMonitoringClaim {
    private var didRelease = false

    func release() {
      guard !didRelease else { return }
      didRelease = true
      PerformanceBatteryMonitoringRegistry.release()
    }
  }

  @MainActor
  private enum PerformanceBatteryMonitoringRegistry {
    private static var ownership = PerformanceBatteryOwnership()

    static func claim() -> PerformanceBatteryMonitoringClaim {
      if let value = ownership.claim(
        currentValue: UIDevice.current.isBatteryMonitoringEnabled
      ) {
        UIDevice.current.isBatteryMonitoringEnabled = value
      }
      return PerformanceBatteryMonitoringClaim()
    }

    static func observeEnabled() -> Bool {
      ownership.observe(currentValue: UIDevice.current.isBatteryMonitoringEnabled)
    }

    static func release() {
      if let value = ownership.release(
        currentValue: UIDevice.current.isBatteryMonitoringEnabled
      ) {
        UIDevice.current.isBatteryMonitoringEnabled = value
      }
    }
  }
#endif
