import Combine
import CryptoKit
import Darwin
import LocalAuthentication
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireTransport
import Security
import SwiftUI
import XCTest

@testable import NearWireViewer

private final class ViewerWorkspaceControlProbe: ViewerWorkspaceSessionControlling,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var clearCompletion: (@Sendable (Result<Void, ViewerWorkspaceMutationFailure>) -> Void)?
  private var clearAfterCommit: (@Sendable () -> Void)?
  private var importCompletion: (@Sendable (Result<Void, ViewerWorkspaceMutationFailure>) -> Void)?
  private var importAfterCommit: (@Sendable () -> Void)?
  private(set) var clearCount = 0
  private(set) var importCount = 0
  private(set) var cancelCount = 0

  func clearCurrentSession(
    afterCommit: @escaping @Sendable () -> Void,
    completion: @escaping @Sendable (Result<Void, ViewerWorkspaceMutationFailure>) -> Void
  ) {
    lock.lock()
    clearCount += 1
    clearAfterCommit = afterCommit
    clearCompletion = completion
    lock.unlock()
  }

  func importCurrentSession(
    from url: URL,
    afterCommit: @escaping @Sendable () -> Void,
    completion: @escaping @Sendable (Result<Void, ViewerWorkspaceMutationFailure>) -> Void
  ) {
    lock.lock()
    importCount += 1
    importAfterCommit = afterCommit
    importCompletion = completion
    lock.unlock()
  }

  func cancelCurrentSessionImport() {
    lock.lock()
    cancelCount += 1
    lock.unlock()
  }

  func completeClear(_ result: Result<Void, ViewerWorkspaceMutationFailure>) {
    lock.lock()
    let completion = clearCompletion
    let afterCommit = clearAfterCommit
    clearCompletion = nil
    clearAfterCommit = nil
    lock.unlock()
    if case .success = result { afterCommit?() }
    completion?(result)
  }

  func completeImport(_ result: Result<Void, ViewerWorkspaceMutationFailure>) {
    lock.lock()
    let completion = importCompletion
    let afterCommit = importAfterCommit
    importCompletion = nil
    importAfterCommit = nil
    lock.unlock()
    if case .success = result { afterCommit?() }
    completion?(result)
  }
}

final class ViewerLocalizationTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    suiteName = "ViewerLocalizationTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    suiteName = nil
    super.tearDown()
  }

  @MainActor
  func testLanguagePreferenceDefaultsToSystemAndPersistsManualChoice() {
    let controller = ViewerLanguageController(
      defaults: defaults,
      systemLocaleProvider: { Locale(identifier: "zh-Hans-CN") }
    )
    XCTAssertEqual(controller.preference, .system)
    XCTAssertEqual(controller.effectiveLocale.identifier, "zh-Hans")

    controller.select(.english)
    XCTAssertEqual(controller.preference, .english)
    XCTAssertEqual(controller.effectiveLocale.identifier, "en")
    XCTAssertEqual(defaults.string(forKey: ViewerLanguageController.defaultsKey), "english")

    let restored = ViewerLanguageController(defaults: defaults)
    XCTAssertEqual(restored.preference, .english)
  }

  @MainActor
  func testInvalidStoredPreferenceFallsBackToSystemAndSystemLocaleCanRefresh() {
    defaults.set("unsupported-value", forKey: ViewerLanguageController.defaultsKey)
    var locale = Locale(identifier: "en-US")
    let controller = ViewerLanguageController(
      defaults: defaults,
      systemLocaleProvider: { locale }
    )
    XCTAssertEqual(controller.preference, .system)
    XCTAssertEqual(defaults.string(forKey: ViewerLanguageController.defaultsKey), "system")
    XCTAssertEqual(controller.effectiveLocale.identifier, "en")

    locale = Locale(identifier: "zh-Hans-CN")
    controller.refreshSystemLocale()
    XCTAssertEqual(controller.effectiveLocale.identifier, "zh-Hans")

    let traditionalChineseController = ViewerLanguageController(
      defaults: defaults,
      systemLocaleProvider: { Locale(identifier: "zh-Hant-TW") }
    )
    XCTAssertEqual(traditionalChineseController.effectiveLocale.identifier, "zh-Hans")
  }

  @MainActor
  func testMalformedPreferenceTypeIsReplacedByCanonicalSystemValue() {
    defaults.set(Data([0x01, 0x02]), forKey: ViewerLanguageController.defaultsKey)
    let controller = ViewerLanguageController(
      defaults: defaults,
      systemLocaleProvider: { Locale(identifier: "en-US") }
    )

    XCTAssertEqual(controller.preference, .system)
    XCTAssertEqual(defaults.string(forKey: ViewerLanguageController.defaultsKey), "system")
  }

  func testSupportedLocaleResolutionUsesSimplifiedChineseForEveryChineseLocale() {
    XCTAssertEqual(
      ViewerLocalization.localizationIdentifier(for: Locale(identifier: "zh-Hans-CN")),
      "zh-Hans"
    )
    XCTAssertEqual(
      ViewerLocalization.localizationIdentifier(for: Locale(identifier: "zh-Hans-HK")),
      "zh-Hans"
    )
    XCTAssertEqual(
      ViewerLocalization.localizationIdentifier(for: Locale(identifier: "zh-CN")),
      "zh-Hans"
    )
    XCTAssertEqual(
      ViewerLocalization.localizationIdentifier(for: Locale(identifier: "zh-Hant-TW")),
      "zh-Hans"
    )
    XCTAssertEqual(
      ViewerLocalization.localizationIdentifier(for: Locale(identifier: "zh-HK")),
      "zh-Hans"
    )
    XCTAssertEqual(
      ViewerLocalization.localizationIdentifier(for: Locale(identifier: "fr-FR")),
      "en"
    )
  }

  func testStringCatalogHasCompleteEnglishAndSimplifiedChineseCoverage() throws {
    let englishStrings = try compiledLocalization("en")
    let simplifiedChineseStrings = try compiledLocalization("zh-Hans")
    XCTAssertGreaterThanOrEqual(englishStrings.count, 500)
    XCTAssertEqual(Set(englishStrings.keys), Set(simplifiedChineseStrings.keys))

    for (key, english) in englishStrings {
      let simplifiedChinese = try XCTUnwrap(simplifiedChineseStrings[key], key)
      XCTAssertFalse(english.isEmpty, key)
      XCTAssertFalse(simplifiedChinese.isEmpty, key)
      XCTAssertEqual(
        formatPlaceholders(in: english),
        formatPlaceholders(in: simplifiedChinese),
        key
      )
    }
  }

  func testCatalogCoversRepresentativeViewerSurfaces() throws {
    let englishStrings = try compiledLocalization("en")
    let simplifiedChineseStrings = try compiledLocalization("zh-Hans")
    let representativeKeys = [
      "Connect an iPhone App",
      "Devices",
      "Event Timeline",
      "Event Inspector",
      "Control Event JSON content",
      "Performance",
      "Viewer language",
      "The requested bounded view is no longer valid.",
      "Viewer identity is unavailable",
      "%@ performance chart. Aggregated average lines and min–max envelopes. %lld buckets.",
    ]
    for key in representativeKeys {
      XCTAssertEqual(englishStrings[key], key)
      XCTAssertNotNil(simplifiedChineseStrings[key], key)
    }
    XCTAssertEqual(simplifiedChineseStrings["Event Timeline"], "事件时间线")
    XCTAssertEqual(simplifiedChineseStrings["Performance"], "性能")
  }

  func testLocalizedFormattingDoesNotTreatApplicationContentAsAViewerKey() throws {
    let chineseStrings = try compiledLocalization("zh-Hans")
    XCTAssertNil(chineseStrings["app.custom.payload"])
    XCTAssertEqual(
      ViewerLocalization.string(
        "app.custom.payload",
        locale: Locale(identifier: "zh-Hans"),
        bundle: .main
      ),
      "app.custom.payload"
    )
    XCTAssertEqual(
      ViewerLocalization.string(
        "Event Timeline",
        locale: Locale(identifier: "zh-Hans"),
        bundle: .main
      ),
      "事件时间线"
    )
    let chinese = try XCTUnwrap(chineseStrings["%lld events/s"])
    XCTAssertEqual(
      String(format: chinese, locale: Locale(identifier: "zh-Hans"), 12),
      "12 个事件/秒"
    )
  }

  @MainActor
  func testSystemNotificationAndManualSelectionRepublishSharedSceneRootsOnce() {
    var systemLocale = Locale(identifier: "en-US")
    let controller = ViewerLanguageController(
      defaults: defaults,
      systemLocaleProvider: { systemLocale }
    )
    var publicationCount = 0
    let publication = controller.objectWillChange.sink { publicationCount += 1 }
    defer { publication.cancel() }

    let eventHost = NSHostingView(
      rootView: Text("Event Timeline").viewerLanguageEnvironment(controller)
    )
    let performanceHost = NSHostingView(
      rootView: Text("Performance").viewerLanguageEnvironment(controller)
    )
    let settingsHost = NSHostingView(
      rootView: ViewerLanguageSettingsView(controller: controller)
        .viewerLanguageEnvironment(controller)
    )
    eventHost.frame = NSRect(x: 0, y: 0, width: 240, height: 80)
    performanceHost.frame = NSRect(x: 0, y: 0, width: 240, height: 80)
    settingsHost.frame = NSRect(x: 0, y: 0, width: 440, height: 240)
    [eventHost, performanceHost, settingsHost].forEach {
      $0.layoutSubtreeIfNeeded()
      $0.displayIfNeeded()
    }

    systemLocale = Locale(identifier: "zh-Hant-TW")
    NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    [eventHost, performanceHost, settingsHost].forEach {
      $0.layoutSubtreeIfNeeded()
      $0.displayIfNeeded()
    }

    XCTAssertEqual(controller.effectiveLocale.identifier, "zh-Hans")
    XCTAssertEqual(publicationCount, 1)

    controller.select(.english)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    eventHost.layoutSubtreeIfNeeded()
    XCTAssertEqual(controller.effectiveLocale.identifier, "en")
  }

  func testViewerSourceBoundaryCoversFixedLocalizationCallsAndAppKitPanels() throws {
    let englishStrings = try compiledLocalization("en")
    let viewerSourceRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("NearWireViewer", isDirectory: true)
    let sourceURLs = try XCTUnwrap(
      FileManager.default.enumerator(
        at: viewerSourceRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )?.allObjects as? [URL]
    ).filter { $0.pathExtension == "swift" }
    XCTAssertFalse(sourceURLs.isEmpty)

    let localizedCall = try NSRegularExpression(
      pattern: #"ViewerLocalization\.(?:string|format)\(\s*\"([^\"\n]+)\""#
    )
    let swiftUILiteral = try NSRegularExpression(
      pattern:
        #"(?:Text|Button|Label|Toggle|Picker|GroupBox|accessibilityLabel|help)\s*\(\s*\"([^\"\n]+)\""#
    )
    let hardCodedPanelText = try NSRegularExpression(
      pattern: #"\b(?:panel|alert)\.(?:title|message|informativeText|prompt)\s*=\s*\""#
    )
    var missingKeys: [String] = []
    var hardCodedPanels: [String] = []

    for url in sourceURLs {
      let source = try String(contentsOf: url, encoding: .utf8)
      let sourceRange = NSRange(source.startIndex..., in: source)
      for expression in [localizedCall, swiftUILiteral] {
        expression.enumerateMatches(in: source, range: sourceRange) { match, _, _ in
          guard
            let match,
            let range = Range(match.range(at: 1), in: source)
          else { return }
          let rawLiteral = String(source[range])
          guard !rawLiteral.contains(#"\("#) else { return }
          let key =
            rawLiteral
            .replacingOccurrences(of: #"\""#, with: "\"")
            .replacingOccurrences(of: #"\\"#, with: #"\"#)
          if englishStrings[key] == nil {
            missingKeys.append("\(url.lastPathComponent): \(key)")
          }
        }
      }
      if hardCodedPanelText.firstMatch(in: source, range: sourceRange) != nil {
        hardCodedPanels.append(url.lastPathComponent)
      }
    }

    XCTAssertEqual(
      missingKeys, [], "Fixed Viewer UI strings missing from the catalog: \(missingKeys)")
    XCTAssertEqual(
      hardCodedPanels,
      [],
      "AppKit panels must use ViewerLocalization for fixed text: \(hardCodedPanels)"
    )
  }

  private func compiledLocalization(_ language: String) throws -> [String: String] {
    let path = try XCTUnwrap(
      Bundle.main.path(
        forResource: "Localizable",
        ofType: "strings",
        inDirectory: nil,
        forLocalization: language
      ),
      language
    )
    return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String], language)
  }

  private func formatPlaceholders(in value: String) -> [String] {
    let pattern =
      #"%(?:[0-9]+\$)?[-+#0 ]*(?:\*|[0-9]+)?(?:\.\*|\.[0-9]+)?(?:hh|h|ll|l|q|L|z|t|j)?[diuoxXfFeEgGaAcCsSp@%]"#
    let expression = try! NSRegularExpression(pattern: pattern)
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression.matches(in: value, range: range).compactMap {
      Range($0.range, in: value).map { String(value[$0]) }
    }
  }
}

final class ViewerWorkspacePresentationTests: XCTestCase {
  func testTimelineHidesNormalAdmissionProgressAndKeepsExceptionalDisposition() {
    for disposition in [
      ViewerEventDisposition.buffered,
      .transportAdmitted,
      .consumerAccepted,
    ] {
      XCTAssertNil(
        ViewerExplorerTimelineDispositionPresentation.visibleDisposition(disposition.rawValue)
      )
    }
    XCTAssertEqual(
      ViewerExplorerTimelineDispositionPresentation.visibleDisposition(
        ViewerEventDisposition.overflowDisplaced.rawValue
      ),
      ViewerEventDisposition.overflowDisplaced.rawValue
    )
  }

  @MainActor
  func testTimelineOnlyMutationDoesNotPublishInspectorPresentation() async {
    let runtimeLogicalID = UUID()
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: runtimeLogicalID,
        liveObservations: ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
      )
    )
    let timeline = ViewerTimelinePresentationObserver(explorer: controller)
    let inspector = ViewerInspectorPresentationObserver(explorer: controller)

    controller.updateFilterDraft { $0.requiresGap = true }
    for _ in 0..<4 { await Task.yield() }

    XCTAssertEqual(timeline.revision, 1)
    XCTAssertEqual(inspector.revision, 0)
  }

  @MainActor
  func testFilterPresentationIgnoresTimelineOnlyPublications() async {
    let runtimeLogicalID = UUID()
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: runtimeLogicalID,
        liveObservations: ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
      )
    )
    let filter = ViewerFilterPresentationObserver(explorer: controller)

    controller.pauseOrResume()
    for _ in 0..<4 { await Task.yield() }
    XCTAssertEqual(filter.revision, 0)

    controller.updateFilterDraft { $0.eventTypeMode = .prefix }
    for _ in 0..<4 { await Task.yield() }
    XCTAssertEqual(filter.revision, 1)
    XCTAssertEqual(filter.value.eventTypeMode, .prefix)

    controller.jumpToLatest()
    for _ in 0..<4 { await Task.yield() }
    XCTAssertEqual(filter.revision, 1)
    _ = controller.sealAndClear()
  }

  func testWorkspaceRegionsExposeDevicesAndIndependentPanelsWithoutSources() {
    XCTAssertEqual(
      ViewerWorkspaceLayout.regions,
      [.devices, .eventTimeline, .eventInspector, .controlComposer]
    )
    XCTAssertEqual(ViewerWorkspaceLayout.regions.count, ViewerWorkspaceRegion.allCases.count)
  }

  func testInspectorOffersOnlyMetadataRawPrettyAndPreview() {
    XCTAssertEqual(
      ViewerExplorerInspectorTab.allCases.map(\.rawValue),
      ["Metadata", "Raw", "Pretty", "Preview"]
    )
  }

  @MainActor
  func testWorkspaceMutationPolicyAllowsConnectedClearButRejectsConnectedImport() {
    XCTAssertTrue(
      ViewerApplicationModel.permitsWorkspaceMutation(.clearEvents, hasBlockingSessions: true)
    )
    XCTAssertFalse(
      ViewerApplicationModel.permitsWorkspaceMutation(.importSession, hasBlockingSessions: true)
    )
    XCTAssertTrue(
      ViewerApplicationModel.permitsWorkspaceMutation(.importSession, hasBlockingSessions: false)
    )
  }

  func testImportCapacityFailureUsesDedicatedSafeGuidance() {
    XCTAssertEqual(
      ViewerWorkspaceMutationFailure.capacityExceeded.operatorMessage,
      "The imported Session is too large for the current memory limit. Import a smaller Session."
    )
    XCTAssertFalse(ViewerWorkspaceMutationFailure.capacityExceeded.operatorMessage.contains("/"))
  }

  @MainActor
  func testWorkspaceOperationsPublishImmediateExclusiveAndCancellableStates() async {
    let runtimeLogicalID = UUID()
    let workspace = ViewerWorkspaceControlProbe()
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: runtimeLogicalID,
        liveObservations: ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID),
        workspaceControl: workspace
      )
    )

    controller.clearCurrentSession()
    XCTAssertEqual(controller.workspaceOperationState, .clearing)
    XCTAssertEqual(workspace.clearCount, 1)
    controller.clearCurrentSession()
    XCTAssertEqual(workspace.clearCount, 1)
    workspace.completeClear(.success(()))
    for _ in 0..<4 { await Task.yield() }
    XCTAssertEqual(controller.workspaceOperationState, .clearCompleted)

    controller.clearWorkspaceOperationPresentation()
    XCTAssertEqual(controller.workspaceOperationState, .idle)
    XCTAssertTrue(controller.beginCurrentSessionImportSelection())
    XCTAssertEqual(controller.workspaceOperationState, .selectingImport)
    controller.importCurrentSession(from: URL(fileURLWithPath: "/tmp/nearwire-import.json"))
    XCTAssertEqual(controller.workspaceOperationState, .importing)
    XCTAssertEqual(workspace.importCount, 1)
    controller.cancelCurrentSessionImport()
    XCTAssertEqual(workspace.cancelCount, 1)
    workspace.completeImport(.failure(.cancelled))
    for _ in 0..<4 { await Task.yield() }
    XCTAssertEqual(controller.workspaceOperationState, .failed(.cancelled))

    controller.clearWorkspaceOperationPresentation()
    XCTAssertTrue(controller.beginCurrentSessionImportSelection())
    controller.cancelCurrentSessionImportSelection()
    XCTAssertEqual(controller.workspaceOperationState, .idle)

    _ = controller.sealAndClear()
  }
}

final class ViewerPerformanceInventoryTests: XCTestCase {
  func testViewerConsumesCoreMetricInventoryWithoutReordering() {
    XCTAssertEqual(
      ViewerPerformanceMetricInventory.descriptors.map(\.key),
      PerformanceMetricKey.allCases
    )
    XCTAssertEqual(
      ViewerPerformanceMetricInventory.descriptors.map(\.group),
      PerformanceMetricKey.allCases.map(\.group)
    )
    XCTAssertEqual(
      ViewerPerformanceMetricInventory.descriptors.map(\.kind),
      PerformanceMetricKey.allCases.map(\.kind)
    )
  }

  func testPerformanceDecoderPreservesMeasurementsAvailabilityAndUnknownRawOnlyValues() throws {
    let outcome = ViewerPerformanceSnapshotDecoder.decode(
      .canonical(
        Data(
          """
          {
            "schemaVersion": 1,
            "sampledAt": "2026-07-14T01:02:03.456Z",
            "sampleIntervalMilliseconds": 1000,
            "process": {"cpuPercent": 0, "memoryFootprintBytes": 0},
            "display": {"estimatedFramesPerSecond": 60},
            "device": {
              "batteryLevel": 0,
              "batteryState": "future-battery-state",
              "thermalState": "future-thermal-state",
              "lowPowerModeEnabled": false,
              "futureMetric": 12
            },
            "transport": {
              "uplinkBytesPerSecond": 0,
              "downlinkBytesPerSecond": 0,
              "uplinkQueueDepth": 0,
              "droppedEventCount": 0
            },
            "unavailable": [
              {"metric": "device.gpuUtilization", "reason": "unsupported"},
              {"metric": "device.powerWatts", "reason": "disabled"},
              {"metric": "device.temperatureCelsius", "reason": "permissionDenied"},
              {"metric": "display.maximumFramesPerSecond", "reason": "temporarilyUnavailable"},
              {"metric": "future.metric", "reason": "unsupported"},
              {"metric": "future.metric", "reason": "disabled"}
            ],
            "futureGroup": {"value": 1}
          }
          """.utf8
        )
      )
    )
    guard case .valid(let decoded) = outcome else {
      return XCTFail("Expected a valid Core V1 performance snapshot")
    }

    XCTAssertEqual(decoded.sampleIntervalMilliseconds, 1_000)
    XCTAssertEqual(decoded.state(for: .processCPUPercent), .numeric(0))
    XCTAssertEqual(decoded.state(for: .processMemoryFootprintBytes), .unsigned(0))
    XCTAssertEqual(decoded.state(for: .deviceBatteryLevel), .numeric(0))
    XCTAssertEqual(decoded.state(for: .deviceBatteryState), .batteryState(.unknown))
    XCTAssertEqual(decoded.state(for: .deviceThermalState), .thermalState(.unknown))
    XCTAssertEqual(decoded.state(for: .deviceLowPowerModeEnabled), .boolean(false))
    XCTAssertEqual(decoded.state(for: .transportDroppedEventCount), .unsigned(0))
    XCTAssertEqual(decoded.state(for: .transportDownlinkQueueDepth), .notCollected)
    XCTAssertEqual(
      decoded.state(for: .deviceGPUUtilization),
      .unavailable(.unsupported)
    )
    XCTAssertEqual(decoded.state(for: .devicePowerWatts), .unavailable(.disabled))
    XCTAssertEqual(
      decoded.state(for: .deviceTemperatureCelsius),
      .unavailable(.permissionDenied)
    )
    XCTAssertEqual(
      decoded.state(for: .displayMaximumFramesPerSecond),
      .unavailable(.temporarilyUnavailable)
    )
    XCTAssertNil(PerformanceMetricKey(rawValue: "future.metric"))
  }

  func testPerformanceDecoderInvalidatesKnownUnavailableConflicts() {
    let identicalDuplicate = ViewerPerformanceSnapshotDecoder.decode(
      .canonical(
        performanceJSON(
          body:
            "\"unavailable\":[{\"metric\":\"process.cpuPercent\",\"reason\":\"disabled\"},{\"metric\":\"process.cpuPercent\",\"reason\":\"disabled\"}]"
        )
      )
    )
    XCTAssertEqual(identicalDuplicate, .invalid(.duplicateKnownUnavailable))

    let duplicate = ViewerPerformanceSnapshotDecoder.decode(
      .canonical(
        performanceJSON(
          body:
            "\"unavailable\":[{\"metric\":\"process.cpuPercent\",\"reason\":\"disabled\"},{\"metric\":\"process.cpuPercent\",\"reason\":\"unsupported\"}]"
        )
      )
    )
    XCTAssertEqual(duplicate, .invalid(.duplicateKnownUnavailable))

    let presentAndUnavailable = ViewerPerformanceSnapshotDecoder.decode(
      .canonical(
        performanceJSON(
          body:
            "\"process\":{\"cpuPercent\":0},\"unavailable\":[{\"metric\":\"process.cpuPercent\",\"reason\":\"disabled\"}]"
        )
      )
    )
    XCTAssertEqual(presentAndUnavailable, .invalid(.presentAndUnavailable))
  }

  func testPerformanceDecoderClassifiesMalformedSchemaCoreAndSizeFailures() {
    XCTAssertEqual(
      ViewerPerformanceSnapshotDecoder.decode(.canonical(Data("{".utf8))),
      .invalid(.malformedJSON)
    )
    XCTAssertEqual(
      ViewerPerformanceSnapshotDecoder.decode(
        .canonical(
          Data(
            "{\"schemaVersion\":2,\"sampledAt\":\"2026-07-14T01:02:03Z\",\"sampleIntervalMilliseconds\":1000}"
              .utf8)
        )
      ),
      .invalid(.unsupportedSchema)
    )
    XCTAssertEqual(
      ViewerPerformanceSnapshotDecoder.decode(
        .canonical(
          Data("{\"schemaVersion\":1,\"sampledAt\":\"2026-07-14T01:02:03Z\"}".utf8)
        )
      ),
      .invalid(.invalidCoreContent)
    )
    XCTAssertEqual(
      ViewerPerformanceSnapshotDecoder.decode(.oversized(byteCount: 65_537)),
      .invalid(.oversizedContent)
    )
    XCTAssertEqual(
      ViewerPerformanceSnapshotDecoder.decode(.canonical(Data(repeating: 0x20, count: 65_537))),
      .invalid(.oversizedContent)
    )

    let prefix =
      "{\"schemaVersion\":1,\"sampledAt\":\"2026-07-14T01:02:03Z\",\"sampleIntervalMilliseconds\":1000,\"future\":\""
    let suffix = "\"}"
    let paddingCount =
      ViewerPerformanceLimits.decoderBufferBytes
      - prefix.utf8.count - suffix.utf8.count
    let exact = Data((prefix + String(repeating: "x", count: paddingCount) + suffix).utf8)
    XCTAssertEqual(exact.count, ViewerPerformanceLimits.decoderBufferBytes)
    guard case .valid = ViewerPerformanceSnapshotDecoder.decode(.canonical(exact)) else {
      return XCTFail("Expected the exact 65,536-byte boundary to decode")
    }
  }

  private func performanceJSON(body: String) -> Data {
    Data(
      "{\"schemaVersion\":1,\"sampledAt\":\"2026-07-14T01:02:03Z\",\"sampleIntervalMilliseconds\":1000,\(body)}"
        .utf8
    )
  }
}

final class ViewerPerformancePresentationTests: XCTestCase {
  func testMetricPresentationUsesExactInventoryAndExplicitCurrentCardSubset() {
    XCTAssertEqual(
      ViewerPerformanceMetricPresentation.all.map(\.key),
      PerformanceMetricKey.allCases
    )
    XCTAssertEqual(
      PerformanceMetricGroup.allCases.flatMap(\.keys),
      PerformanceMetricKey.allCases
    )
    XCTAssertEqual(ViewerPerformanceMetricPresentation.all.count, 16)
    XCTAssertEqual(ViewerPerformanceMetricPresentation.currentCardKeys.count, 12)
    XCTAssertEqual(
      Set(ViewerPerformanceMetricPresentation.currentCardKeys).count,
      ViewerPerformanceMetricPresentation.currentCardKeys.count
    )
    XCTAssertFalse(
      ViewerPerformanceMetricPresentation.currentCardKeys.contains(.deviceGPUUtilization)
    )
    XCTAssertFalse(
      ViewerPerformanceMetricPresentation.currentCardKeys.contains(.devicePowerWatts)
    )
    XCTAssertFalse(
      ViewerPerformanceMetricPresentation.currentCardKeys.contains(.deviceTemperatureCelsius)
    )
    XCTAssertFalse(
      ViewerPerformanceMetricPresentation.currentCardKeys.contains(.transportDownlinkQueueDepth)
    )
    XCTAssertTrue(
      ViewerPerformanceMetricPresentation.all.allSatisfy {
        !$0.title.isEmpty && !$0.unit.isEmpty && !$0.systemImage.isEmpty
      }
    )
    XCTAssertEqual(
      ViewerPerformanceMetricPresentation.descriptor(for: .deviceTemperatureCelsius).unit,
      "°C"
    )
  }

  func testCurrentCardFormattingPreservesMeasuredZeroAndClosedStates() {
    XCTAssertEqual(
      ViewerPerformanceFormatting.cardValue(
        .measured(.numeric(0)),
        for: .processCPUPercent
      ),
      "0%"
    )
    XCTAssertEqual(
      ViewerPerformanceFormatting.cardValue(
        .measured(.numeric(0)),
        for: .deviceBatteryLevel
      ),
      "0%"
    )
    XCTAssertEqual(
      ViewerPerformanceFormatting.cardValue(
        .measured(.unsigned(0)),
        for: .processMemoryFootprintBytes
      ),
      "0 B"
    )
    XCTAssertEqual(
      ViewerPerformanceFormatting.cardValue(
        .measured(.unsigned(1_536)),
        for: .transportUplinkBytesPerSecond
      ),
      "1.5 KiB/s"
    )
    XCTAssertEqual(
      ViewerPerformanceFormatting.cardValue(
        .measured(.thermalState(.unknown)),
        for: .deviceThermalState
      ),
      "Unknown"
    )
    XCTAssertEqual(
      ViewerPerformanceFormatting.cardValue(
        .measured(.boolean(false)),
        for: .deviceLowPowerModeEnabled
      ),
      "Off"
    )
    XCTAssertEqual(
      ViewerPerformanceFormatting.cardValue(
        .unavailable(.unsupported),
        for: .deviceGPUUtilization
      ),
      "Unsupported"
    )
    XCTAssertEqual(
      ViewerPerformanceFormatting.cardValue(.notCollected, for: .devicePowerWatts),
      "Not collected"
    )
    XCTAssertEqual(
      ViewerPerformanceFormatting.cardValue(.noRecentSample, for: .processCPUPercent),
      "No recent sample"
    )
    XCTAssertEqual(
      ViewerPerformanceFormatting.chartValue(0.5, metric: .batteryFraction),
      50
    )
    XCTAssertEqual(
      ViewerPerformanceFormatting.chartAxisValue(1_536, group: .throughput),
      "1.5 KiB/s"
    )
    XCTAssertEqual(ViewerPerformanceFormatting.elapsedTime(90), "1.5m")
  }

  func testAvailabilityFormattingDisclosesEveryRetainedStateCount() {
    var counts = ViewerPerformanceAvailabilityCounts()
    counts.record(.numeric(0))
    counts.record(.unavailable(.permissionDenied))
    counts.record(.unavailable(.temporarilyUnavailable))
    counts.record(.unavailable(.disabled))
    counts.record(.unavailable(.unsupported))
    counts.record(.notCollected)
    counts.recordInvalid()

    XCTAssertEqual(counts.presentation, .measured)
    XCTAssertEqual(
      ViewerPerformanceFormatting.availabilityDetail(counts),
      "1 measured · 1 invalid · 1 permission denied · 1 temporarily unavailable · 1 disabled · 1 unsupported · 1 not collected"
    )
    XCTAssertEqual(
      ViewerPerformanceFormatting.availability(.unavailable(.permissionDenied)),
      "Permission denied"
    )
  }

  @MainActor
  func testPerformanceSummaryComposesAtCompactAndWideWidthsWithoutRuntime() {
    let model = ViewerPerformanceDashboardModel()
    let hostingView = NSHostingView(
      rootView: ViewerPerformanceDashboardContent(model: model, guidance: .selectOneDevice)
    )
    for width in [360.0, 540.0, 980.0] {
      hostingView.frame = NSRect(x: 0, y: 0, width: width, height: 720)
      hostingView.layoutSubtreeIfNeeded()
      XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
      XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }
    XCTAssertEqual(model.diagnostics.phase, .idle)
    XCTAssertTrue(model.availability.isEmpty)
  }

  func testChartProjectionBuildsSixGroupsAndPreservesAggregatedEnvelope() throws {
    let buckets = try chartBuckets(count: 2, samplesPerBucket: 2)
    let projections = try ViewerPerformanceChartProjection.makeAll(buckets: buckets)

    XCTAssertEqual(projections.map(\.group), ViewerPerformanceChartGroupKind.allCases)
    XCTAssertEqual(projections.flatMap(\.metrics), ViewerPerformanceNumericMetric.allCases)
    XCTAssertEqual(projections.reduce(0) { $0 + $1.markCount }, 60)
    let cpu = try XCTUnwrap(projections.first { $0.group == .cpu })
    let first = try XCTUnwrap(cpu.point(metric: .cpuPercent, bucketIndex: 0, buckets: buckets))
    XCTAssertEqual(first.minimum, 1)
    XCTAssertEqual(first.average, 1.5)
    XCTAssertEqual(first.maximum, 2)
    XCTAssertEqual(first.measurementCount, 2)
    XCTAssertEqual(first.segmentStartBucketIndex, 0)
    XCTAssertFalse(first.isDiscontinuous)
    let second = try XCTUnwrap(
      cpu.point(metric: .cpuPercent, bucketIndex: 1, buckets: buckets)
    )
    XCTAssertEqual(cpu.points(for: .cpuPercent), [first, second])
  }

  func testChartProjectionUsesPracticalDashboardBoundAndStaysBelowGlobalMarkLimit() throws {
    let buckets = try chartBuckets(
      count: ViewerPerformanceAggregationLimits.maximumDashboardBuckets,
      samplesPerBucket: 1
    )
    let projections = try ViewerPerformanceChartProjection.makeAll(buckets: buckets)

    XCTAssertEqual(projections.count, 6)
    XCTAssertEqual(projections.map(\.markCount), [720, 360, 360, 360, 720, 1_080])
    XCTAssertEqual(projections.reduce(0) { $0 + $1.markCount }, 3_600)
    XCTAssertEqual(
      try ViewerPerformanceAccounting.chartProjectionBytes(pointCount: 1_200),
      ViewerPerformanceAggregationLimits.maximumChartProjectionBytes
    )
    XCTAssertLessThanOrEqual(
      projections.reduce(0) { $0 + $1.markCount },
      ViewerPerformanceAggregationLimits.maximumTotalMarks
    )
    XCTAssertThrowsError(
      try ViewerPerformanceChartProjection.makeAll(
        buckets: chartBuckets(
          count: ViewerPerformanceAggregationLimits.maximumDashboardBuckets + 1,
          samplesPerBucket: 1
        )
      )
    )
  }

  func testChartAccessibilityUsesAtMost64DeterministicNonColorSummaries() throws {
    var buckets = try chartBuckets(
      count: ViewerPerformanceAggregationLimits.maximumDashboardBuckets,
      samplesPerBucket: 2
    )
    let finalIndex = buckets.count - 1
    buckets[finalIndex].markDiscontinuous(.estimatedFramesPerSecond)
    let projection = try XCTUnwrap(
      ViewerPerformanceChartProjection.makeAll(buckets: buckets).first { $0.group == .display }
    )
    let indices = ViewerPerformanceAccessibilityFormatting.bucketIndices(for: projection)

    XCTAssertEqual(indices.count, 64)
    XCTAssertEqual(indices.first, 0)
    XCTAssertEqual(indices.last, finalIndex)
    XCTAssertEqual(Set(indices).count, indices.count)
    XCTAssertEqual(
      ViewerPerformanceAccessibilityFormatting.chartLabel(projection),
      "Frame Rate performance chart. Aggregated average lines and min–max envelopes. 120 buckets."
    )
    let label = try XCTUnwrap(
      ViewerPerformanceAccessibilityFormatting.bucketLabel(
        finalIndex,
        projection: projection,
        buckets: buckets
      )
    )
    XCTAssertTrue(label.contains("Aggregated bucket 120 of 120. Viewer time"))
    XCTAssertTrue(label.contains("Estimated Frame Rate, unit fps"))
    XCTAssertTrue(label.contains("minimum 3 fps, average 3.5 fps, maximum 4 fps, 2 samples"))
    XCTAssertTrue(label.contains("discontinuous"))
    XCTAssertTrue(label.contains("availability Measured"))
    XCTAssertTrue(label.contains("Maximum Frame Rate, unit fps"))

    let point = try XCTUnwrap(
      projection.point(
        metric: .estimatedFramesPerSecond,
        bucketIndex: finalIndex,
        buckets: buckets
      )
    )
    XCTAssertEqual(String(reflecting: point), "ViewerPerformanceChartPoint(redacted)")
    XCTAssertEqual(String(reflecting: projection), "ViewerPerformanceChartProjection(redacted)")
  }

  func testSingleMeasuredBucketPreparesAnExplicitVisiblePoint() throws {
    let buckets = try chartBuckets(count: 1, samplesPerBucket: 1)
    let cpu = try XCTUnwrap(
      ViewerPerformanceChartProjection.makeAll(buckets: buckets).first { $0.group == .cpu }
    )

    XCTAssertEqual(cpu.series.count, 1)
    XCTAssertEqual(cpu.series[0].metric, .cpuPercent)
    XCTAssertEqual(cpu.series[0].points.count, 1)
    XCTAssertEqual(cpu.markCount, 3)
    XCTAssertTrue(cpu.hasMeasurements)
  }

  func testKeyboardNavigationClampsBucketsAndCyclesMetricSeries() throws {
    let buckets = try chartBuckets(count: 3, samplesPerBucket: 1)
    let projection = try XCTUnwrap(
      ViewerPerformanceChartProjection.makeAll(buckets: buckets).first {
        $0.group == .queueAndDrops
      }
    )

    XCTAssertEqual(
      ViewerPerformanceKeyboardNavigation.selection(
        direction: .right,
        current: nil,
        projection: projection,
        buckets: buckets
      ),
      ViewerPerformanceKeyboardSelection(
        viewerMonotonicNanoseconds: buckets[0].centerMonotonicNanoseconds,
        chartGroup: .queueAndDrops,
        selectedMetric: .uplinkQueueDepth
      )
    )
    XCTAssertEqual(
      ViewerPerformanceKeyboardNavigation.selection(
        direction: .left,
        current: nil,
        projection: projection,
        buckets: buckets
      )?.viewerMonotonicNanoseconds,
      buckets[2].centerMonotonicNanoseconds
    )

    let selected = ViewerPerformanceCrosshair(
      viewerMonotonicNanoseconds: buckets[1].centerMonotonicNanoseconds,
      bucketIndex: 1,
      chartGroup: .queueAndDrops,
      selectedMetric: .uplinkQueueDepth
    )
    XCTAssertEqual(
      ViewerPerformanceKeyboardNavigation.selection(
        direction: .right,
        current: selected,
        projection: projection,
        buckets: buckets
      ),
      ViewerPerformanceKeyboardSelection(
        viewerMonotonicNanoseconds: buckets[2].centerMonotonicNanoseconds,
        chartGroup: .queueAndDrops,
        selectedMetric: .uplinkQueueDepth
      )
    )
    let last = ViewerPerformanceCrosshair(
      viewerMonotonicNanoseconds: buckets[2].centerMonotonicNanoseconds,
      bucketIndex: 2,
      chartGroup: .queueAndDrops,
      selectedMetric: .uplinkQueueDepth
    )
    XCTAssertEqual(
      ViewerPerformanceKeyboardNavigation.selection(
        direction: .right,
        current: last,
        projection: projection,
        buckets: buckets
      )?.viewerMonotonicNanoseconds,
      buckets[2].centerMonotonicNanoseconds
    )
    XCTAssertEqual(
      ViewerPerformanceKeyboardNavigation.selection(
        direction: .down,
        current: selected,
        projection: projection,
        buckets: buckets
      )?.selectedMetric,
      .downlinkQueueDepth
    )
    XCTAssertEqual(
      ViewerPerformanceKeyboardNavigation.selection(
        direction: .up,
        current: selected,
        projection: projection,
        buckets: buckets
      )?.selectedMetric,
      .droppedEventCount
    )
    XCTAssertNil(
      ViewerPerformanceKeyboardNavigation.selection(
        direction: .left,
        current: nil,
        projection: projection,
        buckets: []
      )
    )
  }

  func testChartSegmentsDisconnectBothSidesOfMetricBreaksAndMissingBuckets() throws {
    var buckets = try chartBuckets(count: 4, samplesPerBucket: 1)
    buckets[1].markDiscontinuous(.cpuPercent)
    let projection = try XCTUnwrap(
      ViewerPerformanceChartProjection.makeAll(buckets: buckets).first { $0.group == .cpu }
    )
    XCTAssertEqual(
      (0..<4).compactMap {
        projection.point(metric: .cpuPercent, bucketIndex: $0, buckets: buckets)?
          .segmentStartBucketIndex
      },
      [0, 1, 2, 2]
    )

    var missing = try chartBuckets(count: 3, samplesPerBucket: 1)
    missing[1] = try ViewerPerformanceBucket(
      index: 1,
      lowerMonotonicNanoseconds: 100,
      upperMonotonicNanoseconds: 199
    )
    let missingProjection = try XCTUnwrap(
      ViewerPerformanceChartProjection.makeAll(buckets: missing).first { $0.group == .cpu }
    )
    XCTAssertNil(
      missingProjection.point(metric: .cpuPercent, bucketIndex: 1, buckets: missing)
    )
    XCTAssertEqual(
      missingProjection.point(metric: .cpuPercent, bucketIndex: 2, buckets: missing)?
        .segmentStartBucketIndex,
      2
    )
  }

  func testEveryDiscontinuousBucketUsesAnIsolatedSegmentForUnplacedGapSuppression() throws {
    var buckets = try chartBuckets(count: 4, samplesPerBucket: 1)
    for index in buckets.indices { buckets[index].markAllDiscontinuous() }
    let projections = try ViewerPerformanceChartProjection.makeAll(buckets: buckets)

    for projection in projections {
      for metric in projection.metrics {
        XCTAssertEqual(
          (0..<4).compactMap {
            projection.point(metric: metric, bucketIndex: $0, buckets: buckets)?
              .segmentStartBucketIndex
          },
          [0, 1, 2, 3]
        )
      }
    }
  }

  private func chartBuckets(
    count: Int,
    samplesPerBucket: Int
  ) throws -> [ViewerPerformanceBucket] {
    try (0..<count).map { index in
      let lower = Int64(index * 100)
      var bucket = try ViewerPerformanceBucket(
        index: index,
        lowerMonotonicNanoseconds: lower,
        upperMonotonicNanoseconds: lower + 99
      )
      for sample in 0..<samplesPerBucket {
        let monotonic = lower + Int64(25 + sample * 50)
        try bucket.record(
          chartSnapshot(offset: Double(sample)),
          event: chartEvent(
            sequence: UInt64(index * max(samplesPerBucket, 1) + sample + 1), monotonic: monotonic)
        )
      }
      return bucket
    }
  }

  private func chartSnapshot(offset: Double) throws -> ViewerDecodedPerformanceSnapshot {
    try ViewerDecodedPerformanceSnapshot(
      sampledAt: Date(timeIntervalSince1970: offset),
      sampleIntervalMilliseconds: 1_000,
      states: PerformanceMetricKey.allCases.map { key in
        switch key {
        case .processCPUPercent: return .numeric(1 + offset)
        case .processMemoryFootprintBytes: return .unsigned(UInt64(2 + offset))
        case .displayEstimatedFramesPerSecond: return .numeric(3 + offset)
        case .displayMaximumFramesPerSecond: return .numeric(4 + offset)
        case .deviceBatteryLevel: return .numeric(0.5)
        case .deviceBatteryState: return .batteryState(.unplugged)
        case .deviceThermalState: return .thermalState(.nominal)
        case .deviceLowPowerModeEnabled: return .boolean(false)
        case .transportUplinkQueueDepth: return .unsigned(UInt64(5 + offset))
        case .transportDroppedEventCount: return .unsigned(UInt64(6 + offset))
        case .transportUplinkBytesPerSecond: return .unsigned(UInt64(7 + offset))
        case .transportDownlinkBytesPerSecond: return .unsigned(UInt64(8 + offset))
        case .transportDownlinkQueueDepth: return .unsigned(UInt64(9 + offset))
        case .deviceGPUUtilization, .devicePowerWatts, .deviceTemperatureCelsius:
          return .unavailable(.unsupported)
        }
      }
    )
  }

  private func chartEvent(
    sequence: UInt64,
    monotonic: Int64
  ) throws -> ViewerPerformanceEventCarrier {
    try ViewerPerformanceEventCarrier(
      locator: .memory(observationID: UUID()),
      key: ViewerEventJournalKey(
        runtimeLogicalID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        connectionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        direction: .appToViewer,
        wireSequence: sequence
      ),
      viewerWallMilliseconds: monotonic,
      viewerMonotonicNanoseconds: monotonic,
      content: .canonical(Data("{}".utf8))
    )
  }
}

final class ViewerPerformanceAggregationTests: XCTestCase {
  func testDashboardRangeBoundsUseAtMost120AlignedBuckets() throws {
    let bounds = try ViewerPerformanceRangeBounds(
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 1_199
    )

    XCTAssertEqual(bounds.bucketCount, ViewerPerformanceAggregationLimits.maximumDashboardBuckets)
    XCTAssertEqual(bounds.bucketWidthNanoseconds, 10)
    XCTAssertEqual(try bounds.bucketBounds(at: 0), 0...9)
    XCTAssertEqual(try bounds.bucketBounds(at: 119), 1_190...1_199)
  }

  func testNumericAccumulatorHandlesZeroOne512513And100000SamplesWithoutRawStorage() throws {
    let counts = [0, 1, 512, 513, 100_000]
    for count in counts {
      var accumulator = ViewerPerformanceNumericAccumulator()
      var expectedSum = 0.0
      let center = Int64(count / 2)
      for index in 0..<count {
        let value = Double(index % 10)
        expectedSum += value
        try accumulator.recordMeasurement(
          value,
          viewerMonotonicNanoseconds: Int64(index),
          journalKey: journalKey(UInt64(index)),
          bucketCenterMonotonicNanoseconds: center
        )
      }

      XCTAssertEqual(accumulator.measurementCount, UInt64(count), "count \(count)")
      if count == 0 {
        XCTAssertNil(accumulator.minimum)
        XCTAssertNil(accumulator.average)
        XCTAssertNil(accumulator.maximum)
        XCTAssertNil(accumulator.representative)
      } else {
        XCTAssertEqual(accumulator.minimum, 0, "count \(count)")
        XCTAssertEqual(accumulator.maximum, count == 1 ? 0 : 9, "count \(count)")
        XCTAssertEqual(
          try XCTUnwrap(accumulator.average),
          expectedSum / Double(count),
          accuracy: 0.000_000_001,
          "count \(count)"
        )
        XCTAssertEqual(accumulator.finiteSum, expectedSum, "count \(count)")
        XCTAssertEqual(accumulator.firstViewerMonotonicNanoseconds, 0, "count \(count)")
        XCTAssertEqual(
          accumulator.lastViewerMonotonicNanoseconds,
          Int64(count - 1),
          "count \(count)"
        )
        XCTAssertEqual(
          accumulator.representative?.key,
          journalKey(UInt64(count / 2)),
          "count \(count)"
        )
      }
    }
  }

  func testTenMetricsKeepDisjointContributorsAndCanonicalRepresentativeTies() throws {
    var bucket = try ViewerPerformanceBucket(
      index: 0,
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 100
    )
    for metric in ViewerPerformanceNumericMetric.allCases {
      let states = PerformanceMetricKey.allCases.map { key -> ViewerPerformanceMetricState in
        guard key == metric.key else {
          return key.kind == .unavailableOnly ? .unavailable(.unsupported) : .notCollected
        }
        return disjointMeasurement(for: metric)
      }
      let snapshot = try ViewerDecodedPerformanceSnapshot(
        sampledAt: Date(timeIntervalSince1970: Double(metric.rawValue)),
        sampleIntervalMilliseconds: 1_000,
        states: states
      )
      try bucket.record(
        snapshot,
        event: event(
          sequence: UInt64(metric.rawValue + 1),
          monotonic: Int64(metric.rawValue * 10 + 1)
        )
      )
    }

    for metric in ViewerPerformanceNumericMetric.allCases {
      let accumulator = bucket.numeric.accumulator(for: metric)
      XCTAssertEqual(accumulator.measurementCount, 1, "metric \(metric)")
      XCTAssertEqual(
        accumulator.representative?.key,
        journalKey(UInt64(metric.rawValue + 1)),
        "metric \(metric)"
      )
      XCTAssertEqual(accumulator.nonmeasurements.notCollected, 9, "metric \(metric)")
      let availability = bucket.availability.counts(for: metric.key)
      XCTAssertEqual(availability.measured, 1, "metric \(metric)")
      XCTAssertEqual(availability.notCollected, 9, "metric \(metric)")
    }

    var tie = ViewerPerformanceNumericAccumulator()
    try tie.recordMeasurement(
      2,
      viewerMonotonicNanoseconds: 50,
      journalKey: journalKey(2),
      bucketCenterMonotonicNanoseconds: 50
    )
    try tie.recordMeasurement(
      1,
      viewerMonotonicNanoseconds: 50,
      journalKey: journalKey(1),
      bucketCenterMonotonicNanoseconds: 50
    )
    XCTAssertEqual(tie.representative?.key, journalKey(1))
  }

  func testCategoricalGapAndInvalidStormsRetainOnlyBoundedState() throws {
    var categorical = ViewerPerformanceCategoricalAccumulator<Bool>()
    var details = ViewerPerformanceBoundedDetails()
    let gap = try ViewerPerformanceGapCarrier(
      count: 1,
      firstViewerWallMilliseconds: nil,
      lastViewerWallMilliseconds: nil,
      kind: .unknown,
      applicability: .uncertain
    )
    for index in 0..<100_000 {
      try categorical.record(
        index.isMultiple(of: 2),
        viewerMonotonicNanoseconds: Int64(index),
        key: journalKey(UInt64(index))
      )
      details.append(gap: gap)
      details.append(
        invalid: try ViewerPerformanceInvalidDetail(
          key: journalKey(UInt64(index)),
          viewerMonotonicNanoseconds: Int64(index),
          reason: .invalidCoreContent
        )
      )
    }

    XCTAssertEqual(categorical.first?.value, true)
    XCTAssertEqual(categorical.latest?.value, false)
    XCTAssertEqual(categorical.last?.value, true)
    XCTAssertEqual(categorical.changeCount, 99_999)
    XCTAssertEqual(details.gaps.count, 128)
    XCTAssertEqual(details.invalidSnapshots.count, 128)
    XCTAssertEqual(details.detailLossCount, 199_744)
  }

  func testTenMetricAccumulatorsPreserveStatisticsStatesAndRepresentatives() throws {
    XCTAssertEqual(ViewerPerformanceNumericMetric.allCases.count, 10)
    XCTAssertEqual(
      Set(ViewerPerformanceNumericMetric.allCases.map(\.key)).count,
      ViewerPerformanceNumericMetric.allCases.count
    )
    XCTAssertTrue(
      ViewerPerformanceNumericMetric.allCases.allSatisfy { $0.key.kind == .numeric }
    )

    let runtimeID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let connectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    func key(_ sequence: UInt64) -> ViewerEventJournalKey {
      ViewerEventJournalKey(
        runtimeLogicalID: runtimeID,
        connectionID: connectionID,
        direction: .appToViewer,
        wireSequence: sequence
      )
    }
    var accumulator = ViewerPerformanceNumericAccumulator()
    try accumulator.recordMeasurement(
      20,
      viewerMonotonicNanoseconds: 40,
      journalKey: key(2),
      bucketCenterMonotonicNanoseconds: 50
    )
    try accumulator.recordMeasurement(
      40,
      viewerMonotonicNanoseconds: 60,
      journalKey: key(1),
      bucketCenterMonotonicNanoseconds: 50
    )
    accumulator.recordNonmeasurement(.invalid)
    accumulator.recordNonmeasurement(.unavailable(.unsupported))
    accumulator.recordNonmeasurement(.unavailable(.disabled))
    accumulator.recordNonmeasurement(.unavailable(.permissionDenied))
    accumulator.recordNonmeasurement(.unavailable(.temporarilyUnavailable))
    accumulator.recordNonmeasurement(.notCollected)
    accumulator.markDiscontinuous()

    XCTAssertEqual(accumulator.minimum, 20)
    XCTAssertEqual(accumulator.maximum, 40)
    XCTAssertEqual(accumulator.average, 30)
    XCTAssertEqual(accumulator.finiteSum, 60)
    XCTAssertEqual(accumulator.measurementCount, 2)
    XCTAssertEqual(accumulator.firstViewerMonotonicNanoseconds, 40)
    XCTAssertEqual(accumulator.lastViewerMonotonicNanoseconds, 60)
    XCTAssertEqual(accumulator.representative?.key, key(2))
    XCTAssertEqual(accumulator.nonmeasurements.invalid, 1)
    XCTAssertEqual(accumulator.nonmeasurements.unsupported, 1)
    XCTAssertEqual(accumulator.nonmeasurements.disabled, 1)
    XCTAssertEqual(accumulator.nonmeasurements.permissionDenied, 1)
    XCTAssertEqual(accumulator.nonmeasurements.temporarilyUnavailable, 1)
    XCTAssertEqual(accumulator.nonmeasurements.notCollected, 1)
    XCTAssertTrue(accumulator.isDiscontinuous)

    var finite = ViewerPerformanceNumericAccumulator()
    try finite.recordMeasurement(
      Double.greatestFiniteMagnitude,
      viewerMonotonicNanoseconds: 1,
      journalKey: key(1),
      bucketCenterMonotonicNanoseconds: 1
    )
    try finite.recordMeasurement(
      Double.greatestFiniteMagnitude,
      viewerMonotonicNanoseconds: 2,
      journalKey: key(2),
      bucketCenterMonotonicNanoseconds: 1
    )
    XCTAssertTrue(try XCTUnwrap(finite.average).isFinite)
    XCTAssertTrue(finite.finiteSum.isFinite)
    XCTAssertTrue(finite.sumSaturated)
  }

  func testBucketAggregatesTenMetricsAndBoundedCategoricalChanges() throws {
    let first = try decodedSnapshot(numericOffset: 0, battery: .unplugged, thermal: .nominal)
    let second = try decodedSnapshot(numericOffset: 10, battery: .charging, thermal: .serious)
    var bucket = try ViewerPerformanceBucket(
      index: 0,
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 99
    )
    let firstEvent = try event(sequence: 1, monotonic: 25)
    let secondEvent = try event(sequence: 2, monotonic: 75)
    try bucket.record(first, event: firstEvent)
    try bucket.record(second, event: secondEvent)
    bucket.markDiscontinuous(.cpuPercent)

    for metric in ViewerPerformanceNumericMetric.allCases {
      let accumulator = bucket.numeric.accumulator(for: metric)
      XCTAssertEqual(accumulator.measurementCount, 2)
      XCTAssertNotNil(accumulator.representative)
    }
    XCTAssertTrue(bucket.numeric.accumulator(for: .cpuPercent).isDiscontinuous)
    XCTAssertEqual(bucket.batteryState.first?.value, .unplugged)
    XCTAssertEqual(bucket.batteryState.latest?.value, .charging)
    XCTAssertEqual(bucket.batteryState.last?.value, .unplugged)
    XCTAssertEqual(bucket.batteryState.changeCount, 1)
    XCTAssertEqual(bucket.thermalState.changeCount, 1)
    XCTAssertEqual(bucket.lowPowerMode.changeCount, 0)
  }

  func testDetailsAccountingPresentationAndLedgerStayAtExactCaps() throws {
    var details = ViewerPerformanceBoundedDetails()
    let gap = try ViewerPerformanceGapCarrier(
      count: 1,
      firstViewerWallMilliseconds: nil,
      lastViewerWallMilliseconds: nil,
      kind: .unknown,
      applicability: .uncertain
    )
    let key = try event(sequence: 1, monotonic: 1).key
    for index in 0..<129 {
      details.append(gap: gap)
      details.append(
        invalid: try ViewerPerformanceInvalidDetail(
          key: key,
          viewerMonotonicNanoseconds: Int64(index),
          reason: .invalidCoreContent
        )
      )
    }
    XCTAssertEqual(details.gaps.count, 128)
    XCTAssertEqual(details.invalidSnapshots.count, 128)
    XCTAssertEqual(details.detailLossCount, 2)

    let buckets = try (0..<512).map {
      try ViewerPerformanceBucket(
        index: $0,
        lowerMonotonicNanoseconds: Int64($0),
        upperMonotonicNanoseconds: Int64($0)
      )
    }
    let availability = PerformanceMetricKey.allCases.map {
      ViewerPerformanceAvailabilityEntry(key: $0, state: .notCollected)
    }
    let result = try ViewerPerformanceAggregationResult(
      buckets: buckets,
      details: details,
      availability: availability
    )
    let expectedResultBytes =
      4_096 + 256 + 512 * 2_048 + 128 * 256 + 128 * 128
      + 16 * 64
    XCTAssertEqual(result.accountedBytes, expectedResultBytes)
    XCTAssertLessThanOrEqual(
      result.accountedBytes,
      ViewerPerformanceAggregationLimits.maximumResultBytes
    )
    XCTAssertEqual(ViewerPerformanceAccounting.deterministicPeakBytes, 21_336_064)
    XCTAssertEqual(ViewerPerformanceAggregationLimits.maximumResultBytes, 8_388_608)
    XCTAssertEqual(ViewerPerformanceAggregationLimits.maximumLedgerBytes, 16_777_216)
    XCTAssertEqual(
      try ViewerPerformancePresentationBounds.maximumMarkCount(bucketCount: 512), 12_288)
    let accessible = try ViewerPerformancePresentationBounds.accessibilityBucketIndices(
      bucketCount: 512
    )
    XCTAssertEqual(accessible.count, 64)
    XCTAssertEqual(accessible.first, 0)
    XCTAssertEqual(accessible.last, 511)
    XCTAssertEqual(Set(accessible).count, accessible.count)

    let ledger = ViewerPerformanceMemoryLedger()
    let reservation = try XCTUnwrap(
      ledger.reserve(
        owner: .completedResult,
        bytes: ViewerPerformanceAggregationLimits.maximumLedgerBytes
      )
    )
    XCTAssertEqual(ledger.usedBytes, 16_777_216)
    XCTAssertNil(try ledger.reserve(owner: .crosshair, bytes: 1))
    XCTAssertTrue(ledger.release(reservation))
    XCTAssertFalse(ledger.release(reservation))
    XCTAssertEqual(ledger.usedBytes, 0)
    XCTAssertEqual(ledger.reservationCount, 0)

    var active = try XCTUnwrap(ledger.reserve(owner: .activeReducer, bytes: 1_024))
    active = try XCTUnwrap(ledger.resize(active, to: 2_048))
    XCTAssertEqual(active.bytes, 2_048)
    XCTAssertEqual(ledger.usedBytes, 2_048)
    XCTAssertTrue(ledger.owns(active))
    let completed = try ledger.transfer(active, to: .completedResult)
    XCTAssertEqual(completed.owner, .completedResult)
    XCTAssertFalse(ledger.owns(active))
    XCTAssertTrue(ledger.owns(completed))
    let reduced = try XCTUnwrap(ledger.resize(completed, to: 1_024))
    XCTAssertEqual(ledger.usedBytes, 1_024)
    XCTAssertTrue(ledger.release(reduced))
    XCTAssertEqual(ledger.usedBytes, 0)
    XCTAssertFalse(String(reflecting: result).contains("process.cpuPercent"))
  }

  func testEveryDeterministicAccountingFormulaMatchesTheOwnershipContract() throws {
    XCTAssertEqual(ViewerPerformanceAccounting.controllerSourceBytes, 4_096)
    XCTAssertEqual(ViewerPerformanceAccounting.cacheKeyBytes, 256)
    XCTAssertEqual(ViewerPerformanceAccounting.resultBaseBytes, 4_096)
    XCTAssertEqual(ViewerPerformanceAccounting.bucketBytes, 2_048)
    XCTAssertEqual(ViewerPerformanceAccounting.detailedGapBytes, 256)
    XCTAssertEqual(ViewerPerformanceAccounting.invalidDetailBytes, 128)
    XCTAssertEqual(ViewerPerformanceAccounting.availabilityEntryBytes, 64)
    XCTAssertEqual(ViewerPerformanceAccounting.modelWrapperBytes, 1_024)
    XCTAssertEqual(ViewerPerformanceAccounting.deliveryWrapperBytes, 256)
    XCTAssertEqual(ViewerPerformanceAccounting.tooltipBytes, 2_048)
    XCTAssertEqual(ViewerPerformanceAccounting.crosshairBytes, 64)

    let emptyResultBytes = 4_096 + 256 + 16 * 64
    XCTAssertEqual(
      try ViewerPerformanceAccounting.resultBytes(
        bucketCount: 0,
        detailedGapCount: 0,
        invalidDetailCount: 0,
        availabilityCount: 16
      ),
      emptyResultBytes
    )
    let populatedBytes = emptyResultBytes + 3 * 2_048 + 2 * 256 + 1 * 128
    XCTAssertEqual(
      try ViewerPerformanceAccounting.resultBytes(
        bucketCount: 3,
        detailedGapCount: 2,
        invalidDetailCount: 1,
        availabilityCount: 16
      ),
      populatedBytes
    )
    XCTAssertEqual(
      try ViewerPerformanceAccounting.activeReducerBytes(
        bucketCount: 3,
        detailedGapCount: 2,
        invalidDetailCount: 1
      ),
      populatedBytes
    )
    XCTAssertThrowsError(
      try ViewerPerformanceAccounting.resultBytes(
        bucketCount: 513,
        detailedGapCount: 0,
        invalidDetailCount: 0,
        availabilityCount: 16
      )
    )
  }

  private func decodedSnapshot(
    numericOffset: Double,
    battery: BatteryState,
    thermal: ThermalState
  ) throws -> ViewerDecodedPerformanceSnapshot {
    let states = PerformanceMetricKey.allCases.map { key -> ViewerPerformanceMetricState in
      switch key {
      case .processCPUPercent: return .numeric(1 + numericOffset)
      case .processMemoryFootprintBytes: return .unsigned(UInt64(2 + numericOffset))
      case .displayEstimatedFramesPerSecond: return .numeric(3 + numericOffset)
      case .displayMaximumFramesPerSecond: return .numeric(4 + numericOffset)
      case .deviceBatteryLevel: return .numeric(0.5)
      case .deviceBatteryState: return .batteryState(battery)
      case .deviceThermalState: return .thermalState(thermal)
      case .deviceLowPowerModeEnabled: return .boolean(false)
      case .transportUplinkQueueDepth: return .unsigned(UInt64(5 + numericOffset))
      case .transportDroppedEventCount: return .unsigned(UInt64(6 + numericOffset))
      case .transportUplinkBytesPerSecond: return .unsigned(UInt64(7 + numericOffset))
      case .transportDownlinkBytesPerSecond: return .unsigned(UInt64(8 + numericOffset))
      case .transportDownlinkQueueDepth: return .unsigned(UInt64(9 + numericOffset))
      case .deviceGPUUtilization, .devicePowerWatts, .deviceTemperatureCelsius:
        return .unavailable(.unsupported)
      }
    }
    return try ViewerDecodedPerformanceSnapshot(
      sampledAt: Date(timeIntervalSince1970: 1),
      sampleIntervalMilliseconds: 1_000,
      states: states
    )
  }

  private func benchmarkPerformanceContent(
    measured: Bool,
    alternateCategory: Bool
  ) -> Data {
    let numeric =
      measured
      ? "\"process\":{\"cpuPercent\":1,\"memoryFootprintBytes\":2},\"display\":{\"estimatedFramesPerSecond\":3,\"maximumFramesPerSecond\":4},\"transport\":{\"uplinkBytesPerSecond\":5,\"downlinkBytesPerSecond\":6,\"uplinkQueueDepth\":7,\"downlinkQueueDepth\":8,\"droppedEventCount\":9},"
      : ""
    let battery = alternateCategory ? "charging" : "unplugged"
    let thermal = alternateCategory ? "serious" : "nominal"
    let batteryLevel = measured ? "0.5" : "null"
    return Data(
      "{\"schemaVersion\":1,\"sampledAt\":\"2026-07-14T01:02:03Z\",\"sampleIntervalMilliseconds\":1000,\(numeric)\"device\":{\"batteryLevel\":\(batteryLevel),\"batteryState\":\"\(battery)\",\"thermalState\":\"\(thermal)\",\"lowPowerModeEnabled\":\(alternateCategory)},\"unavailable\":[{\"metric\":\"device.gpuUtilization\",\"reason\":\"unsupported\"},{\"metric\":\"device.powerWatts\",\"reason\":\"unsupported\"},{\"metric\":\"device.temperatureCelsius\",\"reason\":\"unsupported\"}]}"
        .utf8
    )
  }

  private func event(sequence: UInt64, monotonic: Int64) throws -> ViewerPerformanceEventCarrier {
    try ViewerPerformanceEventCarrier(
      locator: .memory(observationID: UUID()),
      key: ViewerEventJournalKey(
        runtimeLogicalID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        connectionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        direction: .appToViewer,
        wireSequence: sequence
      ),
      viewerWallMilliseconds: monotonic,
      viewerMonotonicNanoseconds: monotonic,
      content: .canonical(Data("{}".utf8))
    )
  }

  private func journalKey(_ sequence: UInt64) -> ViewerEventJournalKey {
    ViewerEventJournalKey(
      runtimeLogicalID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      connectionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      direction: .appToViewer,
      wireSequence: sequence
    )
  }

  private func disjointMeasurement(
    for metric: ViewerPerformanceNumericMetric
  ) -> ViewerPerformanceMetricState {
    switch metric {
    case .estimatedFramesPerSecond, .maximumFramesPerSecond, .cpuPercent, .batteryFraction:
      return .numeric(Double(metric.rawValue + 1))
    case .memoryFootprintBytes, .uplinkBytesPerSecond, .downlinkBytesPerSecond,
      .uplinkQueueDepth, .downlinkQueueDepth, .droppedEventCount:
      return .unsigned(UInt64(metric.rawValue + 1))
    }
  }
}

final class ViewerFoundationTests: XCTestCase {
  func testPairingGeneratorUsesCanonicalAlphabetAndRejectsBiasedBytes() throws {
    let generator = ViewerPairingCodeGenerator { _ in
      [255, 0, 1, 2, 3, 4, 5]
    }

    XCTAssertEqual(try generator.generate().canonicalValue, "ABCDEF")
  }

  func testPairingGeneratorPropagatesRandomSourceFailure() {
    let generator = ViewerPairingCodeGenerator { _ in
      throw ViewerPairingCodeGenerationError()
    }

    XCTAssertThrowsError(try generator.generate()) { error in
      XCTAssertEqual(error as? ViewerPairingCodeGenerationError, ViewerPairingCodeGenerationError())
    }
  }

  func testPairingGeneratorFailsClosedWhenRandomSourceNeverProducesUsableBytes() {
    let generator = ViewerPairingCodeGenerator { count in
      Array(repeating: 255, count: count)
    }

    XCTAssertThrowsError(try generator.generate()) { error in
      XCTAssertEqual(error as? ViewerPairingCodeGenerationError, ViewerPairingCodeGenerationError())
    }
  }

  @MainActor
  func testSupportedWindowAppearancesStartOneRuntimeAndStopIdempotently() async throws {
    let generationCount = LockedTestCounter()
    let listener = FakeViewerSecureListener(
      eventsOnStart: [.ready(port: 49_152), .serviceRegistered(exact: true)]
    )
    let identity = try EndpointID(rawValue: "viewer-test")
    let model = ViewerApplicationModel(
      preferences: ViewerPreferences(requiresApproval: { false }, setRequiresApproval: { _ in }),
      dependencies: ViewerRuntimeDependencies(
        loadIdentity: {
          ViewerPreparedIdentity(
            installationID: identity,
            makeListener: { _ in listener }
          )
        },
        resetTLSIdentity: {},
        resetAllIdentity: {},
        generatePairingCode: {
          generationCount.increment()
          return try PairingCode("ABCDEF")
        }
      )
    )

    ViewerWindowRuntimeLifecycle.ensureRuntime(for: model, isRunningUnitTests: false)
    ViewerWindowRuntimeLifecycle.ensureRuntime(for: model, isRunningUnitTests: false)
    await waitForStatus(.listening(code: "ABCDEF", paused: false), in: model)

    XCTAssertEqual(model.status, .listening(code: "ABCDEF", paused: false))
    XCTAssertEqual(generationCount.value, 1)

    model.closeWindow()
    model.closeWindow()
    _ = await model.prepareForTermination()
    XCTAssertEqual(model.status, .stopped)
  }

  @MainActor
  func testPairingRefreshKeepsOldListenerUntilReplacementCommits() async throws {
    let first = FakeViewerSecureListener(
      eventsOnStart: [.ready(port: 49_152), .serviceRegistered(exact: true)]
    )
    let replacement = FakeViewerSecureListener()
    let factory = LockedListenerFactory([first, replacement])
    let codes = LockedPairingCodeSequence(["ABCDEF", "MNPQRS"])
    let model = makeApplicationModel(listenerFactory: factory, pairingCodes: codes)

    model.openWindow()
    await waitForStatus(.listening(code: "ABCDEF", paused: false), in: model)
    XCTAssertEqual(model.status, .listening(code: "ABCDEF", paused: false))

    model.refreshPairingCode()
    XCTAssertEqual(model.status, .listening(code: "ABCDEF", paused: false))
    XCTAssertEqual(first.cancelCount, 0)

    replacement.emit(.ready(port: 49_153))
    XCTAssertEqual(model.status, .listening(code: "ABCDEF", paused: false))
    replacement.emit(.serviceRegistered(exact: true))
    await waitForStatus(.listening(code: "MNPQRS", paused: false), in: model)

    XCTAssertEqual(model.status, .listening(code: "MNPQRS", paused: false))
    XCTAssertEqual(first.cancelCount, 1)
    XCTAssertEqual(replacement.cancelCount, 0)
    XCTAssertEqual(
      factory.advertisements.map(\.identity.instanceName), ["NearWire-ABCDEF", "NearWire-MNPQRS"])
  }

  @MainActor
  func testReplacementFailurePreservesRegisteredListenerAndCode() async throws {
    let first = FakeViewerSecureListener(
      eventsOnStart: [.ready(port: 49_152), .serviceRegistered(exact: true)]
    )
    let replacementCancelled = expectation(description: "Replacement listener cancelled")
    let replacement = FakeViewerSecureListener(onCancel: { replacementCancelled.fulfill() })
    let factory = LockedListenerFactory([first, replacement])
    let model = makeApplicationModel(
      listenerFactory: factory,
      pairingCodes: LockedPairingCodeSequence(["ABCDEF", "MNPQRS"])
    )
    model.openWindow()
    await waitForStatus(.listening(code: "ABCDEF", paused: false), in: model)

    model.refreshPairingCode()
    replacement.emit(
      .failed(
        SecureTransportError(
          code: .driverFailure,
          message: "Safe test failure.",
          disposition: .connectionTerminal
        )
      )
    )
    await fulfillment(of: [replacementCancelled], timeout: 1)

    XCTAssertEqual(model.status, .listening(code: "ABCDEF", paused: false))
    XCTAssertEqual(first.cancelCount, 0)
    XCTAssertEqual(replacement.cancelCount, 1)
  }

  @MainActor
  func testRegistrationCollisionRetriesWithFreshCodeAndBoundedGeneration() async throws {
    let collision = FakeViewerSecureListener(
      eventsOnStart: [.ready(port: 49_152), .serviceRegistered(exact: false)]
    )
    let exact = FakeViewerSecureListener(
      eventsOnStart: [.serviceRegistered(exact: true), .ready(port: 49_153)]
    )
    let codes = LockedPairingCodeSequence(["ABCDEF", "MNPQRS"])
    let model = makeApplicationModel(
      listenerFactory: LockedListenerFactory([collision, exact]),
      pairingCodes: codes
    )

    model.openWindow()
    await waitForStatus(.listening(code: "MNPQRS", paused: false), in: model)

    XCTAssertEqual(model.status, .listening(code: "MNPQRS", paused: false))
    XCTAssertEqual(collision.cancelCount, 1)
    XCTAssertEqual(codes.requestCount, 2)
  }

  @MainActor
  func testRegistrationCollisionExhaustionFailsAfterThreeFreshCodes() async throws {
    let listeners = (0..<3).map { index in
      FakeViewerSecureListener(
        eventsOnStart: [
          .ready(port: UInt16(49_152 + index)),
          .serviceRegistered(exact: false),
        ]
      )
    }
    let codes = LockedPairingCodeSequence(["ABCDEF", "MNPQRS", "TUVWXY"])
    let model = makeApplicationModel(
      listenerFactory: LockedListenerFactory(listeners),
      pairingCodes: codes
    )

    model.openWindow()
    await waitForStatus(.failed(.listenerUnavailable), in: model)

    XCTAssertEqual(model.status, .failed(.listenerUnavailable))
    XCTAssertEqual(codes.requestCount, 3)
    XCTAssertEqual(listeners.map(\.cancelCount), [1, 1, 1])
  }

  @MainActor
  func testRegisteredServiceRemovalPublishesFreshCodeInsteadOfKeepingMisleadingState()
    async throws
  {
    let first = FakeViewerSecureListener(
      eventsOnStart: [.ready(port: 49_152), .serviceRegistered(exact: true)]
    )
    let recovered = FakeViewerSecureListener(
      eventsOnStart: [.ready(port: 49_153), .serviceRegistered(exact: true)]
    )
    let model = makeApplicationModel(
      listenerFactory: LockedListenerFactory([first, recovered]),
      pairingCodes: LockedPairingCodeSequence(["ABCDEF", "MNPQRS"])
    )
    model.openWindow()
    await waitForStatus(.listening(code: "ABCDEF", paused: false), in: model)
    XCTAssertEqual(model.status, .listening(code: "ABCDEF", paused: false))

    first.emit(.serviceRemoved)
    await waitForStatus(.listening(code: "MNPQRS", paused: false), in: model)

    XCTAssertEqual(model.status, .listening(code: "MNPQRS", paused: false))
    XCTAssertEqual(first.cancelCount, 1)
  }

  @MainActor
  func testLocalNetworkFailureUsesFixedRecoveryAndStaleCallbacksStayStopped() async throws {
    let listenerStarted = expectation(description: "Listener started")
    let listener = FakeViewerSecureListener(onStart: { listenerStarted.fulfill() })
    let model = makeApplicationModel(
      listenerFactory: LockedListenerFactory([listener]),
      pairingCodes: LockedPairingCodeSequence(["ABCDEF"])
    )
    model.openWindow()
    let failedExplorer = try XCTUnwrap(model.explorerController)
    let failedComposer = try XCTUnwrap(model.composerController)
    await fulfillment(of: [listenerStarted], timeout: 1)
    listener.emit(
      .failed(
        SecureTransportError(
          code: .localNetworkUnavailable,
          message: "An underlying value that must not reach UI.",
          disposition: .connectionTerminal
        )
      )
    )
    await waitForStatus(.failed(.localNetworkUnavailable), in: model)
    await waitUntilExplorer {
      failedExplorer.pendingCleanupWorkCount == 0 && failedComposer.pendingCleanupWorkCount == 0
    }
    XCTAssertEqual(model.status, .failed(.localNetworkUnavailable))
    XCTAssertTrue(failedExplorer.timelineRows.isEmpty)
    XCTAssertNil(failedExplorer.inspectorMetadata)
    XCTAssertEqual(failedComposer.contentJSON, "")

    model.retry()
    model.closeWindow()
    listener.emit(.ready(port: 49_152))
    listener.emit(.serviceRegistered(exact: true))
    _ = await model.prepareForTermination()
    XCTAssertEqual(model.status, .stopped)
  }

  @MainActor
  func testPairingGenerationFailureIsNotMisreportedAsIdentityFailure() async throws {
    let model = makeApplicationModel(
      listenerFactory: LockedListenerFactory([]),
      pairingCodes: LockedPairingCodeSequence([])
    )
    model.openWindow()
    await waitForStatus(.failed(.pairingUnavailable), in: model)
    XCTAssertEqual(model.status, .failed(.pairingUnavailable))
  }

  func testPresentationErrorsExposeOnlyFixedRecoveryText() {
    XCTAssertEqual(
      ViewerPresentationError.localNetworkUnavailable.recovery,
      "Allow local network access in System Settings, then retry."
    )
    XCTAssertFalse(ViewerPresentationError.listenerUnavailable.title.isEmpty)
  }

  @MainActor
  func testRootViewComposesWithoutStartingRuntime() {
    let model = makeApplicationModel(
      listenerFactory: LockedListenerFactory([]),
      pairingCodes: LockedPairingCodeSequence([])
    )
    let hostingView = NSHostingView(rootView: ViewerRootView(model: model))
    hostingView.frame = NSRect(
      x: 0,
      y: 0,
      width: ViewerWorkspaceLayout.minimumWindowWidth,
      height: ViewerWorkspaceLayout.minimumWindowHeight
    )
    hostingView.layoutSubtreeIfNeeded()

    XCTAssertEqual(
      ViewerWorkspaceLayout.regions,
      [
        .devices, .eventTimeline, .eventInspector, .controlComposer,
      ]
    )
    XCTAssertGreaterThanOrEqual(
      ViewerWorkspaceLayout.minimumWindowWidth,
      ViewerWorkspaceLayout.timelineMinimumWidth + ViewerWorkspaceLayout.inspectorMinimumWidth
    )
    XCTAssertLessThan(
      ViewerWorkspaceLayout.composerMinimumHeight,
      ViewerWorkspaceLayout.minimumWindowHeight
    )
    XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
    XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    XCTAssertEqual(model.status, .stopped)
  }

  @MainActor
  func testApplicationTerminatesOnlyAfterTheLastViewerWindowCloses() {
    XCTAssertTrue(
      ViewerAppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared)
    )
  }

  @MainActor
  func testRunningWorkspaceRendersAtSupportedSizesAndAppearances() async throws {
    let listener = FakeViewerSecureListener(
      eventsOnStart: [.ready(port: 49_152), .serviceRegistered(exact: true)]
    )
    let model = makeApplicationModel(
      listenerFactory: LockedListenerFactory([listener]),
      pairingCodes: LockedPairingCodeSequence(["ABCDEF"])
    )
    model.openWindow()
    await waitForStatus(.listening(code: "ABCDEF", paused: false), in: model)

    let sizes: [(String, CGSize)] = [
      (
        "minimum",
        CGSize(
          width: ViewerWorkspaceLayout.minimumWindowWidth,
          height: ViewerWorkspaceLayout.minimumWindowHeight
        )
      ),
      ("standard", CGSize(width: 1_280, height: 800)),
      ("wide", CGSize(width: 1_440, height: 900)),
    ]
    let appearances: [(String, NSAppearance.Name)] = [
      ("light", .aqua),
      ("dark", .darkAqua),
    ]

    for (appearanceName, appearance) in appearances {
      for (sizeName, size) in sizes {
        let hostingView = NSHostingView(rootView: ViewerRootView(model: model))
        hostingView.appearance = NSAppearance(named: appearance)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        let probes = descendantViews(of: ViewerWorkspaceLayoutProbeView.self, in: hostingView)
        let analysisProbe = try XCTUnwrap(probes.first { $0.kind == .analysis })
        let timelineToolbarProbe = try XCTUnwrap(
          probes.first { $0.kind == .timelineToolbar }
        )
        let composerProbe = try XCTUnwrap(probes.first { $0.kind == .composer })
        let analysisFrame = analysisProbe.convert(analysisProbe.bounds, to: hostingView)
        let timelineToolbarFrame = timelineToolbarProbe.convert(
          timelineToolbarProbe.bounds,
          to: hostingView
        )
        let composerFrame = composerProbe.convert(composerProbe.bounds, to: hostingView)
        XCTAssertGreaterThanOrEqual(
          analysisFrame.height,
          ViewerWorkspaceLayout.analysisMinimumHeight - 1,
          "Analysis is vertically compressed at \(appearanceName) \(sizeName): \(analysisFrame)"
        )
        XCTAssertGreaterThanOrEqual(
          composerFrame.height,
          ViewerWorkspaceLayout.composerMinimumHeight - 1,
          "Composer is below its bounded viewport at \(appearanceName) \(sizeName): \(composerFrame)"
        )
        XCTAssertLessThanOrEqual(
          composerFrame.height,
          ViewerWorkspaceLayout.composerMaximumHeight + 1,
          "Composer exceeds its bounded viewport at \(appearanceName) \(sizeName): \(composerFrame)"
        )
        XCTAssertTrue(
          hostingView.bounds.insetBy(dx: -1, dy: -1).contains(composerFrame),
          "Composer escapes the window at \(appearanceName) \(sizeName): \(composerFrame)"
        )
        XCTAssertTrue(
          analysisFrame.insetBy(dx: -1, dy: -1).contains(timelineToolbarFrame),
          "Timeline toolbar escapes Analysis at \(appearanceName) \(sizeName): analysis \(analysisFrame), toolbar \(timelineToolbarFrame)"
        )
        XCTAssertFalse(
          analysisFrame.intersects(composerFrame),
          "Analysis overlaps Composer at \(appearanceName) \(sizeName): analysis \(analysisFrame), composer \(composerFrame)"
        )
        XCTAssertFalse(
          timelineToolbarFrame.intersects(composerFrame),
          "Timeline toolbar overlaps Composer at \(appearanceName) \(sizeName): toolbar \(timelineToolbarFrame), composer \(composerFrame)"
        )
        let data = try XCTUnwrap(renderedPNGData(of: hostingView))
        let image = try XCTUnwrap(NSImage(data: data))
        XCTAssertEqual(image.size, size)
        let attachment = XCTAttachment(image: image)
        attachment.name = "NearWire workspace \(appearanceName) \(sizeName)"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
    }

    _ = await model.prepareForTermination()
  }

  @MainActor
  func testPerformanceWindowRendersAtSupportedSizesAndAppearances() async throws {
    let listener = FakeViewerSecureListener(
      eventsOnStart: [.ready(port: 49_152), .serviceRegistered(exact: true)]
    )
    let model = makeApplicationModel(
      listenerFactory: LockedListenerFactory([listener]),
      pairingCodes: LockedPairingCodeSequence(["ABCDEF"])
    )
    model.openWindow()
    await waitForStatus(.listening(code: "ABCDEF", paused: false), in: model)

    let sizes: [(String, CGSize)] = [
      (
        "minimum",
        CGSize(
          width: ViewerPerformanceWindowLayout.minimumWidth,
          height: ViewerPerformanceWindowLayout.minimumHeight
        )
      ),
      (
        "default",
        CGSize(
          width: ViewerPerformanceWindowLayout.defaultWidth,
          height: ViewerPerformanceWindowLayout.defaultHeight
        )
      ),
      ("wide", CGSize(width: 1_440, height: 900)),
    ]
    let appearances: [(String, NSAppearance.Name)] = [
      ("light", .aqua),
      ("dark", .darkAqua),
    ]

    for (appearanceName, appearance) in appearances {
      for (sizeName, size) in sizes {
        let hostingView = NSHostingView(
          rootView: ViewerPerformanceWindowRootView(model: model)
        )
        hostingView.appearance = NSAppearance(named: appearance)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let data = try XCTUnwrap(renderedPNGData(of: hostingView))
        let image = try XCTUnwrap(NSImage(data: data))
        XCTAssertEqual(image.size, size)
        XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
        let attachment = XCTAttachment(image: image)
        attachment.name = "NearWire Performance \(appearanceName) \(sizeName)"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
    }

    _ = await model.prepareForTermination()
  }

  @MainActor
  func testFilterSheetRendersExpandedControlsWithinMinimumBounds() {
    let runtimeLogicalID = UUID()
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: runtimeLogicalID,
        liveObservations: ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
      )
    )
    let hostingView = NSHostingView(
      rootView: ViewerExplorerFilterSheet(
        explorer: controller,
        isPresented: .constant(true)
      )
      .environment(\.locale, Locale(identifier: "en"))
    )
    controller.updateFilterDraft {
      $0.fromDate = Date(timeIntervalSince1970: 1)
      $0.throughDate = Date(timeIntervalSince1970: 2)
      $0.jsonMode = .equals
      $0.jsonScalarKind = .string
    }
    hostingView.frame = NSRect(x: 0, y: 0, width: 620, height: 660)
    hostingView.layoutSubtreeIfNeeded()
    hostingView.displayIfNeeded()

    let editors = descendantViews(of: ViewerOperatorTextView.self, in: hostingView)
    XCTAssertEqual(
      Set(editors.compactMap { $0.accessibilityLabel() }),
      Set([
        "Event type", "Application identifier", "Application version", "JSON path",
        "Comparison value",
      ])
    )
    let editorFrames = editors.map { $0.convert($0.bounds, to: hostingView) }
    XCTAssertTrue(
      editorFrames.allSatisfy { $0.width >= 120 },
      "Unexpected filter editor frames: \(editorFrames)"
    )
    let editorOrigins = editorFrames.map(\.minY).sorted()
    XCTAssertTrue(
      zip(editorOrigins, editorOrigins.dropFirst()).allSatisfy { previous, next in
        next - previous >= 30
      },
      "Filter editors do not have enough vertical separation: \(editorFrames)"
    )
    let scrollViews = descendantViews(of: NSScrollView.self, in: hostingView)
    let outerScroll = scrollViews.max {
      $0.convert($0.bounds, to: hostingView).height
        < $1.convert($1.bounds, to: hostingView).height
    }
    let outerFrame = outerScroll.map { $0.convert($0.bounds, to: hostingView) }
    XCTAssertGreaterThanOrEqual(outerFrame?.width ?? 0, 500)
    XCTAssertGreaterThanOrEqual(outerFrame?.height ?? 0, 400)
    XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
    XCTAssertGreaterThan(hostingView.fittingSize.height, 0)

    if let data = renderedPNGData(of: hostingView), let image = NSImage(data: data) {
      let attachment = XCTAttachment(image: image)
      attachment.name = "NearWire Filters expanded minimum layout"
      attachment.lifetime = .keepAlways
      add(attachment)
    } else {
      XCTFail("The minimum-size filter sheet could not be rendered offscreen.")
    }

    let chineseHostingView = NSHostingView(
      rootView: ViewerExplorerFilterSheet(
        explorer: controller,
        isPresented: .constant(true)
      )
      .environment(\.locale, Locale(identifier: "zh-Hans"))
    )
    chineseHostingView.frame = NSRect(x: 0, y: 0, width: 620, height: 660)
    chineseHostingView.layoutSubtreeIfNeeded()
    chineseHostingView.displayIfNeeded()
    let chineseEditors = descendantViews(of: ViewerOperatorTextView.self, in: chineseHostingView)
    XCTAssertEqual(
      Set(chineseEditors.compactMap { $0.accessibilityLabel() }),
      Set(["事件类型", "应用标识", "应用版本", "JSON 路径", "比较值"])
    )
    let chineseFrames = chineseEditors.map { $0.convert($0.bounds, to: chineseHostingView) }
    XCTAssertTrue(chineseFrames.allSatisfy { $0.width >= 120 })
    _ = controller.sealAndClear()
  }

  @MainActor
  func testNativeTextControlsBoundExactEditsAndExposeOnlyExplicitInspectorCopy() async throws {
    var buffer = ViewerIncrementalTextBuffer(
      maximumUTF8Bytes: 8,
      maximumUnicodeScalars: 4
    )
    let editor = ViewerOperatorTextView(frame: .zero)
    editor.controlStyle = .singleLine
    editor.onBoundedEdit = { range, replacement in
      buffer.replaceCharacters(in: range, with: replacement) == .applied
    }

    XCTAssertTrue(
      editor.textView(
        editor,
        shouldChangeTextIn: NSRange(location: 0, length: 0),
        replacementString: "é🙂"
      )
    )
    editor.string = buffer.value
    XCTAssertTrue(
      editor.textView(
        editor,
        shouldChangeTextIn: NSRange(location: 1, length: 2),
        replacementString: "ab"
      )
    )
    editor.string = buffer.value
    XCTAssertTrue(
      editor.textView(
        editor,
        shouldChangeTextIn: NSRange(location: 3, length: 0),
        replacementString: "🙂"
      )
    )
    editor.string = buffer.value
    let accepted = editor.string
    XCTAssertFalse(
      editor.textView(
        editor,
        shouldChangeTextIn: NSRange(location: 5, length: 0),
        replacementString: "x"
      )
    )
    XCTAssertEqual(editor.string, accepted)
    XCTAssertEqual(buffer.value, accepted)
    XCTAssertFalse(editor.isProcessingNativeEdit)
    XCTAssertFalse(
      editor.textView(
        editor,
        shouldChangeTextIn: NSRange(location: 0, length: 0),
        replacementString: "\n"
      )
    )
    XCTAssertTrue(editor.isEditable)
    XCTAssertTrue(editor.isSelectable)
    XCTAssertTrue(editor.acceptsFirstResponder)
    XCTAssertFalse(editor.isRichText)
    XCTAssertFalse(editor.importsGraphics)
    XCTAssertTrue(editor.responds(to: #selector(NSText.copy(_:))))
    XCTAssertTrue(editor.responds(to: #selector(NSText.cut(_:))))
    XCTAssertTrue(editor.responds(to: #selector(NSText.paste(_:))))
    XCTAssertTrue(Mirror(reflecting: editor).children.isEmpty)
    XCTAssertFalse(String(reflecting: editor).contains(accepted))

    var submitted = false
    editor.onSubmit = { submitted = true }
    XCTAssertTrue(editor.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    XCTAssertTrue(submitted)

    let multiline = ViewerOperatorTextView(frame: .zero)
    multiline.controlStyle = .multiline
    multiline.onBoundedEdit = { _, _ in true }
    XCTAssertTrue(
      multiline.textView(
        multiline,
        shouldChangeTextIn: NSRange(location: 0, length: 0),
        replacementString: "\n"
      )
    )

    var pastedBuffer = ViewerIncrementalTextBuffer(
      maximumUTF8Bytes: 8,
      maximumUnicodeScalars: 4
    )
    let pasteEditor = ViewerOperatorTextView(frame: .zero)
    pasteEditor.onBoundedEdit = { range, replacement in
      pastedBuffer.replaceCharacters(in: range, with: replacement) == .applied
    }
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("NearWireTests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects(["é🙂" as NSString]))
    pasteEditor.setSelectedRange(NSRange(location: 0, length: 0))
    XCTAssertTrue(pasteEditor.readSelection(from: pasteboard, type: .string))
    XCTAssertEqual(pasteEditor.string, "é🙂")
    XCTAssertEqual(pastedBuffer.value, "é🙂")

    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects(["ab" as NSString]))
    pasteEditor.setSelectedRange(NSRange(location: 1, length: 2))
    XCTAssertTrue(pasteEditor.readSelection(from: pasteboard, type: .string))
    XCTAssertEqual(pasteEditor.string, "éab")
    XCTAssertEqual(pastedBuffer.value, "éab")

    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects(["🙂🙂" as NSString]))
    pasteEditor.setSelectedRange(NSRange(location: 3, length: 0))
    XCTAssertTrue(pasteEditor.readSelection(from: pasteboard, type: .string))
    XCTAssertEqual(pasteEditor.string, "éab")
    XCTAssertEqual(pastedBuffer.value, "éab")

    let received = ViewerReceivedEventTextView(frame: .zero)
    received.string = "private Event content"
    let clipboardItems = [
      NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: ""),
      NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: ""),
      NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: ""),
      NSMenuItem(
        title: "Select All",
        action: #selector(NSText.selectAll(_:)),
        keyEquivalent: ""
      ),
    ]
    XCTAssertFalse(received.isEditable)
    XCTAssertTrue(received.isSelectable)
    XCTAssertTrue(received.acceptsFirstResponder)
    XCTAssertFalse(received.isRichText)
    XCTAssertFalse(received.importsGraphics)
    XCTAssertTrue(received.registeredDraggedTypes.isEmpty)
    received.updateMenu(copyTitle: "Copy", selectAllTitle: "Select All")
    XCTAssertEqual(
      received.menu?.items.map(\.action),
      [#selector(NSText.copy(_:)), #selector(NSText.selectAll(_:))]
    )
    received.setSelectedRange(NSRange(location: 0, length: 7))
    XCTAssertTrue(received.validateUserInterfaceItem(clipboardItems[0]))
    XCTAssertFalse(received.validateUserInterfaceItem(clipboardItems[1]))
    XCTAssertFalse(received.validateUserInterfaceItem(clipboardItems[2]))
    XCTAssertTrue(received.validateUserInterfaceItem(clipboardItems[3]))
    XCTAssertTrue(Mirror(reflecting: received).children.isEmpty)
    XCTAssertFalse(String(reflecting: received).contains("private Event content"))
    received.clearSensitiveState()
    XCTAssertEqual(received.string, "")

    let wrappedHostingView = NSHostingView(
      rootView: ViewerReceivedEventText(
        text: String(repeating: "0123456789", count: 200),
        accessibilityText: "Received Event content"
      )
      .frame(width: 220, height: 120)
    )
    wrappedHostingView.frame = NSRect(x: 0, y: 0, width: 220, height: 120)
    wrappedHostingView.layoutSubtreeIfNeeded()
    let wrapped = try XCTUnwrap(
      descendantViews(of: ViewerReceivedEventTextView.self, in: wrappedHostingView).first
    )
    let wrappedScroll = try XCTUnwrap(
      descendantViews(of: ViewerReceivedEventTextScrollView.self, in: wrappedHostingView).first
    )
    XCTAssertFalse(wrappedScroll.hasHorizontalScroller)
    XCTAssertEqual(wrapped.textContainer?.widthTracksTextView, true)
    XCTAssertLessThanOrEqual(wrapped.frame.width, 220)
    for _ in 0..<100 where wrapped.frame.height <= 120 {
      try await Task.sleep(nanoseconds: 10_000_000)
      wrappedHostingView.layoutSubtreeIfNeeded()
    }
    XCTAssertGreaterThan(wrapped.frame.height, 120)

    let measurementGate = BlockingViewerOperationGate()
    let measurementCompletions = LockedStringSequence()
    let measurementWorker = ViewerReceivedEventTextMeasurementWorker { request in
      measurementGate.run()
      return CGFloat(request.text.utf8.count)
    }
    measurementWorker.submit(
      ViewerReceivedEventTextMeasurementRequest(text: "first", width: 100, fontSize: 13)
    ) { _ in measurementCompletions.append("first") }
    XCTAssertEqual(measurementGate.waitUntilEntered(), .success)
    measurementWorker.submit(
      ViewerReceivedEventTextMeasurementRequest(text: "replaced", width: 100, fontSize: 13)
    ) { _ in measurementCompletions.append("replaced") }
    measurementWorker.submit(
      ViewerReceivedEventTextMeasurementRequest(text: "latest", width: 100, fontSize: 13)
    ) { _ in measurementCompletions.append("latest") }
    XCTAssertEqual(measurementWorker.retainedWorkCountForTesting, 2)
    measurementGate.release()
    for _ in 0..<100
    where measurementCompletions.values.count < 2
      || measurementWorker.retainedWorkCountForTesting != 0
    {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(measurementCompletions.values, ["first", "latest"])
    XCTAssertEqual(measurementWorker.retainedWorkCountForTesting, 0)

    var filter = ViewerExplorerFilterDraft()
    XCTAssertEqual(
      filter.replaceText(
        .search,
        range: NSRange(location: 0, length: 0),
        replacement: "device"
      ),
      .applied
    )
    XCTAssertEqual(
      filter.replaceText(
        .search,
        range: NSRange(location: 0, length: 6),
        replacement: String(repeating: "x", count: 513)
      ),
      .rejected(.byteLimit)
    )
    XCTAssertEqual(filter.searchText, "device")
  }

  @MainActor
  func testControlComposerScalesToCompactWidthWithDeterministicEditorFocusOrder() throws {
    let runtimeID = UUID()
    let owner = FakeAdmissionHandoffOwner(runtimeLogicalID: runtimeID)
    let controller = try ViewerControlComposerController(
      runtimeLogicalID: runtimeID,
      sessionControl: owner
    )
    let hostingView = NSHostingView(
      rootView: ViewerControlComposerView(controller: controller)
        .environment(\.locale, Locale(identifier: "en"))
    )
    hostingView.frame = NSRect(x: 0, y: 0, width: 620, height: 900)
    hostingView.layoutSubtreeIfNeeded()

    let editors = descendantViews(of: ViewerOperatorTextView.self, in: hostingView)
    XCTAssertEqual(editors.count, 3)
    XCTAssertEqual(
      editors.compactMap { $0.accessibilityLabel() },
      ["Control Event type", "Control Event JSON content", "TTL milliseconds"]
    )
    XCTAssertTrue(editors.allSatisfy(\.acceptsFirstResponder))
    let editorFrames = editors.map { $0.convert($0.bounds, to: hostingView) }
    XCTAssertTrue(
      editorFrames.allSatisfy { $0.width >= 100 && $0.height >= 20 },
      "Composer editors must retain a nonzero interactive frame: \(editorFrames)"
    )
    let eventTypeEditor = try XCTUnwrap(
      editors.first { $0.accessibilityLabel() == "Control Event type" }
    )
    let hitPoint = NSPoint(
      x: eventTypeEditor.bounds.midX,
      y: eventTypeEditor.bounds.midY
    )
    XCTAssertTrue(eventTypeEditor.hitTest(hitPoint) === eventTypeEditor)
    let window = NSWindow(
      contentRect: hostingView.frame,
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.contentView = hostingView
    XCTAssertTrue(window.makeFirstResponder(eventTypeEditor))
    XCTAssertTrue(window.firstResponder === eventTypeEditor)
    eventTypeEditor.insertText(
      "app.debug.command",
      replacementRange: NSRange(location: 0, length: 0)
    )
    XCTAssertEqual(controller.eventType, "app.debug.command")
    XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
    XCTAssertGreaterThan(hostingView.fittingSize.height, 0)

    let chineseHostingView = NSHostingView(
      rootView: ViewerControlComposerView(controller: controller)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
    )
    chineseHostingView.frame = NSRect(x: 0, y: 0, width: 620, height: 900)
    chineseHostingView.layoutSubtreeIfNeeded()
    let chineseEditors = descendantViews(of: ViewerOperatorTextView.self, in: chineseHostingView)
    XCTAssertEqual(chineseEditors.count, 3)
    XCTAssertEqual(
      chineseEditors.compactMap { $0.accessibilityLabel() },
      ["控制事件类型", "控制事件 JSON 内容", "TTL（毫秒）"]
    )
    XCTAssertTrue(chineseEditors.allSatisfy(\.acceptsFirstResponder))
    controller.sealAndClear()
  }

  @MainActor
  func testRunningRootComposesEventExplorerAndRuntimeCleanupSealsIt() async throws {
    let listener = FakeViewerSecureListener(
      eventsOnStart: [.ready(port: 49_152), .serviceRegistered(exact: true)]
    )
    let model = makeApplicationModel(
      listenerFactory: LockedListenerFactory([listener]),
      pairingCodes: LockedPairingCodeSequence(["ABCDEF"])
    )

    model.openWindow()
    await waitForStatus(.listening(code: "ABCDEF", paused: false), in: model)
    let explorer = try XCTUnwrap(model.explorerController)
    let analysis = try XCTUnwrap(model.analysisCoordinator)
    let composer = try XCTUnwrap(model.composerController)
    let hostingView = NSHostingView(rootView: ViewerRootView(model: model))
    hostingView.frame = NSRect(
      x: 0,
      y: 0,
      width: ViewerWorkspaceLayout.minimumWindowWidth,
      height: ViewerWorkspaceLayout.minimumWindowHeight
    )
    hostingView.layoutSubtreeIfNeeded()

    XCTAssertEqual(analysis.mode, .events)
    XCTAssertFalse(analysis.performanceController.isAnalysisActive)
    XCTAssertTrue(explorer.usesAllDevices)
    XCTAssertTrue(
      explorer.replaceFilterCharacters(
        .eventType,
        range: NSRange(location: 0, length: 0),
        replacement: "log.network"
      )
    )
    explorer.updateFilterDraft {
      $0.eventTypeMode = .prefix
      $0.directions = ["appToViewer"]
      $0.requiresDrop = true
    }
    XCTAssertEqual(explorer.activeFilterCount, 3)
    XCTAssertNoThrow(try explorer.filterDraft.makeFilter())
    explorer.prepareExport(.completeSession)
    XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
    XCTAssertGreaterThan(hostingView.fittingSize.height, 0)

    _ = await model.prepareForTermination()
    XCTAssertNil(model.explorerController)
    XCTAssertNil(model.analysisCoordinator)
    XCTAssertNil(model.composerController)
    XCTAssertTrue(analysis.diagnostics.isSealed)
    XCTAssertTrue(analysis.performanceController.diagnostics.isSealed)
    XCTAssertTrue(explorer.timelineRows.isEmpty)
    XCTAssertNil(explorer.inspectorMetadata)
    XCTAssertTrue(composer.targetRows.isEmpty)
    XCTAssertTrue(composer.resultRows.isEmpty)
    XCTAssertEqual(composer.eventType, "")
    XCTAssertEqual(composer.contentJSON, "")
    XCTAssertEqual(composer.ttlText, "")
  }

  func testBuiltApplicationMetadataAndPrivacyManifestMatchDiscoveryContract() throws {
    let info = try XCTUnwrap(Bundle.main.infoDictionary)
    XCTAssertEqual(info["NSBonjourServices"] as? [String], ["_nearwire._tcp"])
    XCTAssertEqual(
      info["NSLocalNetworkUsageDescription"] as? String,
      "NearWire advertises a local service so your iPhone apps can connect to this Mac."
    )

    let privacyURL = try XCTUnwrap(
      Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
    )
    let privacyData = try Data(contentsOf: privacyURL)
    let privacy = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: privacyData, format: nil) as? [String: Any]
    )
    XCTAssertEqual(privacy["NSPrivacyTracking"] as? Bool, false)
    XCTAssertNil(privacy["NSPrivacyTrackingDomains"])
    let accessed = try XCTUnwrap(privacy["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
    XCTAssertEqual(accessed.count, 1)
    XCTAssertEqual(
      accessed[0]["NSPrivacyAccessedAPIType"] as? String,
      "NSPrivacyAccessedAPICategoryUserDefaults"
    )
    XCTAssertEqual(accessed[0]["NSPrivacyAccessedAPITypeReasons"] as? [String], ["CA92.1"])
    let collected = try XCTUnwrap(privacy["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
    XCTAssertEqual(collected.count, 1)
    XCTAssertEqual(
      collected[0]["NSPrivacyCollectedDataType"] as? String,
      "NSPrivacyCollectedDataTypeDeviceID"
    )
    XCTAssertEqual(collected[0]["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
    XCTAssertEqual(collected[0]["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
    XCTAssertEqual(
      collected[0]["NSPrivacyCollectedDataTypePurposes"] as? [String],
      ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
    )
  }

  func testRunningApplicationHasRequiredFoundationNetworkEntitlements() throws {
    let task = try XCTUnwrap(SecTaskCreateFromSelf(nil))
    XCTAssertEqual(
      SecTaskCopyValueForEntitlement(
        task,
        "com.apple.security.app-sandbox" as CFString,
        nil
      ) as? Bool,
      true
    )
    XCTAssertEqual(
      SecTaskCopyValueForEntitlement(
        task,
        "com.apple.security.network.client" as CFString,
        nil
      ) as? Bool,
      true
    )
    XCTAssertEqual(
      SecTaskCopyValueForEntitlement(
        task,
        "com.apple.security.network.server" as CFString,
        nil
      ) as? Bool,
      true
    )
    for forbidden in [
      "com.apple.developer.networking.multicast",
      "keychain-access-groups",
      "com.apple.security.application-groups",
    ] {
      XCTAssertNil(SecTaskCopyValueForEntitlement(task, forbidden as CFString, nil))
    }
  }

  func testCertificateBuilderProducesAndValidatesFixedProfile() throws {
    let creationDate = Date(timeIntervalSince1970: 1_800_000_000)
    let builder = ViewerCertificateBuilder(
      randomBytes: { count in Array(repeating: 0x31, count: count) },
      now: { creationDate }
    )
    let key = try builder.createEphemeralPrivateKey()
    let material = try builder.build(privateKey: key)
    let profile = try builder.validate(
      certificate: material.certificate,
      privateKey: key,
      at: creationDate,
      requireRenewalHeadroom: false
    )

    XCTAssertEqual(profile.serial, Data(repeating: 0x31, count: 16))
    XCTAssertEqual(profile.publicKeyBytes.count, 65)
    XCTAssertEqual(profile.notBefore, creationDate.addingTimeInterval(-300))
    XCTAssertEqual(
      profile.notAfter, creationDate.addingTimeInterval(ViewerCertificateBuilder.lifetime))
    XCTAssertEqual(
      SecCertificateCopySubjectSummary(material.certificate) as String?,
      ViewerCertificateBuilder.commonName
    )
  }

  func testCertificateBuilderRejectsRenewalWindow() throws {
    let creationDate = Date(timeIntervalSince1970: 1_800_000_000)
    let builder = ViewerCertificateBuilder(
      randomBytes: { count in Array(repeating: 0x22, count: count) },
      now: { creationDate }
    )
    let key = try builder.createEphemeralPrivateKey()
    let material = try builder.build(privateKey: key)
    let renewalDate = material.notAfter.addingTimeInterval(-29 * 24 * 60 * 60)

    XCTAssertThrowsError(
      try builder.validate(certificate: material.certificate, privateKey: key, at: renewalDate)
    ) { error in
      XCTAssertEqual(error as? ViewerCertificateError, .invalidValidity)
    }
  }

  func testCertificateBuilderEnforcesExactValidityBoundaries() throws {
    let creationDate = Date(timeIntervalSince1970: 1_800_000_000)
    let builder = ViewerCertificateBuilder(
      randomBytes: { count in Array(repeating: 0, count: count) },
      now: { creationDate }
    )
    let key = try builder.createEphemeralPrivateKey()
    let material = try builder.build(privateKey: key)

    let profile = try builder.validate(
      certificate: material.certificate,
      privateKey: key,
      at: material.notBefore,
      requireRenewalHeadroom: false
    )
    XCTAssertEqual(profile.serial.first, 1)
    XCTAssertNoThrow(
      try builder.validate(
        certificate: material.certificate,
        privateKey: key,
        at: material.notAfter,
        requireRenewalHeadroom: false
      )
    )
    XCTAssertThrowsError(
      try builder.validate(
        certificate: material.certificate,
        privateKey: key,
        at: material.notBefore.addingTimeInterval(-1),
        requireRenewalHeadroom: false
      )
    )
    XCTAssertNoThrow(
      try builder.validate(
        certificate: material.certificate,
        privateKey: key,
        at: material.notAfter.addingTimeInterval(-ViewerCertificateBuilder.renewalWindow)
      )
    )
    XCTAssertThrowsError(
      try builder.validate(
        certificate: material.certificate,
        privateKey: key,
        at: material.notAfter.addingTimeInterval(-ViewerCertificateBuilder.renewalWindow + 1)
      )
    )
  }

  func testCertificateBuilderRejectsWrongKeyAndTamperedSignature() throws {
    let creationDate = Date(timeIntervalSince1970: 1_800_000_000)
    let builder = ViewerCertificateBuilder(
      randomBytes: { count in Array(repeating: 0x41, count: count) },
      now: { creationDate }
    )
    let key = try builder.createEphemeralPrivateKey()
    let material = try builder.build(privateKey: key)
    let otherKey = try builder.createEphemeralPrivateKey()

    XCTAssertThrowsError(
      try builder.validate(
        certificate: material.certificate,
        privateKey: otherKey,
        at: creationDate,
        requireRenewalHeadroom: false
      )
    ) { error in
      XCTAssertEqual(error as? ViewerCertificateError, .keyMismatch)
    }

    var tamperedDER = material.der
    tamperedDER[tamperedDER.index(before: tamperedDER.endIndex)] ^= 0x01
    let tamperedCertificate = try XCTUnwrap(
      SecCertificateCreateWithData(nil, tamperedDER as CFData)
    )
    XCTAssertThrowsError(
      try builder.validate(
        certificate: tamperedCertificate,
        privateKey: key,
        at: creationDate,
        requireRenewalHeadroom: false
      )
    ) { error in
      XCTAssertEqual(error as? ViewerCertificateError, .invalidSignature)
    }
  }

  func testCertificateBuilderRejectsInvalidRandomByteCount() throws {
    let builder = ViewerCertificateBuilder(
      randomBytes: { _ in [1] },
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
    let key = try builder.createEphemeralPrivateKey()

    XCTAssertThrowsError(try builder.build(privateKey: key)) { error in
      XCTAssertEqual(error as? ViewerCertificateError, .randomUnavailable)
    }
  }

  func testIdentityStorePersistsSeparatelyAndResetsWithDocumentedScopes() throws {
    let names = ViewerKeychainNames.isolated()
    let store = ViewerIdentityStore(names: names)
    addTeardownBlock { try? store.resetAllIdentity() }

    do {
      _ = try store.loadOrCreateMaterial()
    } catch {
      XCTFail("Initial file-based identity material creation failed: \(error)")
      return
    }

    let first: ViewerRuntimeIdentity
    do {
      first = try store.loadOrCreate()
    } catch {
      XCTFail("Initial identity creation failed: \(error)")
      return
    }
    let reloaded = try store.loadOrCreate()
    XCTAssertEqual(first.installationID, reloaded.installationID)
    XCTAssertEqual(
      SecCertificateCopyData(first.certificate) as Data,
      SecCertificateCopyData(reloaded.certificate) as Data
    )
    XCTAssertNil(SecKeyCopyExternalRepresentation(first.privateKey, nil))

    try store.resetTLSIdentity()
    let afterTLSReset = try store.loadOrCreate()
    XCTAssertEqual(first.installationID, afterTLSReset.installationID)
    XCTAssertNotEqual(
      SecCertificateCopyData(first.certificate) as Data,
      SecCertificateCopyData(afterTLSReset.certificate) as Data
    )

    try store.resetAllIdentity()
    let afterFullReset = try store.loadOrCreate()
    XCTAssertNotEqual(first.installationID, afterFullReset.installationID)
  }

  func testStableSignerUpdateBoundaryProbe() throws {
    let signedConfiguration = try XCTUnwrap(Bundle.main.infoDictionary)
    guard
      let phaseValue = signedConfiguration["NearWireSignerProbePhase"] as? String,
      !phaseValue.isEmpty
    else {
      throw XCTSkip("Set the stable-signer probe build settings to run this packaging test.")
    }
    let phase = try XCTUnwrap(StableSignerProbePhase(rawValue: phaseValue))
    let token = try XCTUnwrap(signedConfiguration["NearWireSignerProbeToken"] as? String)
    let buildID = try XCTUnwrap(signedConfiguration["NearWireSignerProbeBuildID"] as? String)
    let stateRoot = try XCTUnwrap(
      signedConfiguration["NearWireSignerProbeStateRoot"] as? String
    )
    guard isValidStableSignerProbeComponent(token),
      isValidStableSignerProbeComponent(buildID),
      isValidStableSignerProbeStateRoot(stateRoot)
    else {
      throw ViewerTestError.invalidProbeConfiguration
    }

    let probeDirectory = URL(fileURLWithPath: stateRoot, isDirectory: true)
      .appendingPathComponent(token, isDirectory: true)
    let store = ViewerIdentityStore(names: .isolated("stable-signer-\(token)"))
    let expectedURL = probeDirectory.appendingPathComponent("expected.json")
    let deniedURL = probeDirectory.appendingPathComponent("deny-complete")
    let hostFingerprint = try currentStableSignerProbeFingerprint()
    let signer = hostFingerprint.signer
    let bundleVersion = try XCTUnwrap(
      Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    )
    let productPath = Bundle.main.bundleURL.path

    switch phase {
    case .create:
      try FileManager.default.createDirectory(
        at: probeDirectory,
        withIntermediateDirectories: true
      )
      guard !FileManager.default.fileExists(atPath: expectedURL.path) else {
        throw ViewerTestError.invalidProbeConfiguration
      }
      let identity = try store.loadOrCreate()
      try assertPrivateKeyCanSign(identity.privateKey)
      let expected = StableSignerProbeRecord(
        installationID: identity.installationID.rawValue,
        certificateHash: Data(
          SHA256.hash(data: SecCertificateCopyData(identity.certificate) as Data)
        ),
        certificatePersistentReference: try persistentReference(
          for: identity.certificate
        ),
        signer: signer,
        codeDirectoryHash: hostFingerprint.codeDirectoryHash,
        bundleVersion: bundleVersion,
        buildID: buildID,
        productPath: productPath
      )
      try JSONEncoder().encode(expected).write(to: expectedURL, options: .atomic)

    case .deny:
      let expected = try loadStableSignerProbeRecord(from: expectedURL)
      guard buildID != expected.buildID, productPath != expected.productPath,
        bundleVersion != expected.bundleVersion,
        hostFingerprint.codeDirectoryHash != expected.codeDirectoryHash,
        signer != expected.signer,
        signer.designatedRequirement != expected.signer.designatedRequirement,
        !FileManager.default.fileExists(atPath: deniedURL.path)
      else {
        throw ViewerTestError.invalidProbeConfiguration
      }
      XCTAssertThrowsError(try store.loadOrCreate())
      XCTAssertThrowsError(try store.resetTLSIdentity())
      XCTAssertThrowsError(try store.resetAllIdentity())
      assertUnrelatedSignerCannotReadUseOrDelete(
        names: .isolated("stable-signer-\(token)"),
        certificatePersistentReference: expected.certificatePersistentReference
      )

    case .verify:
      let expected = try loadStableSignerProbeRecord(from: expectedURL)
      guard buildID != expected.buildID, productPath != expected.productPath,
        bundleVersion != expected.bundleVersion,
        hostFingerprint.codeDirectoryHash != expected.codeDirectoryHash,
        signer == expected.signer,
        FileManager.default.fileExists(atPath: deniedURL.path)
      else {
        throw ViewerTestError.invalidProbeConfiguration
      }
      let reloaded = try store.loadOrCreate()
      XCTAssertEqual(reloaded.installationID.rawValue, expected.installationID)
      XCTAssertEqual(
        Data(SHA256.hash(data: SecCertificateCopyData(reloaded.certificate) as Data)),
        expected.certificateHash
      )
      try assertPrivateKeyCanSign(reloaded.privateKey)

      try store.resetTLSIdentity()
      let afterTLSReset = try store.loadOrCreate()
      XCTAssertEqual(afterTLSReset.installationID.rawValue, expected.installationID)
      XCTAssertNotEqual(
        Data(SHA256.hash(data: SecCertificateCopyData(afterTLSReset.certificate) as Data)),
        expected.certificateHash
      )
      try store.resetAllIdentity()
      try FileManager.default.removeItem(at: probeDirectory)
    }
  }

  private func isValidStableSignerProbeComponent(_ value: String) -> Bool {
    (6...64).contains(value.count)
      && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
  }

  private func isValidStableSignerProbeStateRoot(_ value: String) -> Bool {
    let url = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
    return url.path == value
      && url.lastPathComponent == "nearwire-viewer-stable-signer-probe"
      && url.path.contains("/Library/Containers/com.nearwire.viewer/Data/tmp/")
  }

  private func loadStableSignerProbeRecord(from url: URL) throws -> StableSignerProbeRecord {
    try JSONDecoder().decode(StableSignerProbeRecord.self, from: Data(contentsOf: url))
  }

  private func currentStableSignerProbeFingerprint() throws -> (
    signer: StableSignerProbeFingerprint,
    codeDirectoryHash: Data
  ) {
    var dynamicCode: SecCode?
    guard SecCodeCopySelf([], &dynamicCode) == errSecSuccess, let dynamicCode else {
      throw ViewerTestError.signingMetadataUnavailable
    }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess,
      let staticCode
    else {
      throw ViewerTestError.signingMetadataUnavailable
    }
    var requirement: SecRequirement?
    guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
      let requirement
    else {
      throw ViewerTestError.signingMetadataUnavailable
    }
    var requirementText: CFString?
    guard SecRequirementCopyString(requirement, [], &requirementText) == errSecSuccess,
      let requirementText
    else {
      throw ViewerTestError.signingMetadataUnavailable
    }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &information
      ) == errSecSuccess,
      let values = information as? [CFString: Any],
      let teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String,
      !teamIdentifier.isEmpty,
      let certificates = values[kSecCodeInfoCertificates] as? [SecCertificate],
      let leafCertificate = certificates.first,
      let codeDirectoryHash = values[kSecCodeInfoUnique] as? Data
    else {
      throw ViewerTestError.signingMetadataUnavailable
    }
    return (
      signer: StableSignerProbeFingerprint(
        teamIdentifier: teamIdentifier,
        certificateHash: Data(
          SHA256.hash(data: SecCertificateCopyData(leafCertificate) as Data)
        ),
        designatedRequirement: requirementText as String
      ),
      codeDirectoryHash: codeDirectoryHash
    )
  }

  private func persistentReference(for certificate: SecCertificate) throws -> Data {
    let context = LAContext()
    context.interactionNotAllowed = true
    let query: [CFString: Any] = [
      kSecClass: kSecClassCertificate,
      kSecMatchItemList: [certificate],
      kSecReturnPersistentRef: true,
      kSecMatchLimit: kSecMatchLimitOne,
      kSecUseDataProtectionKeychain: false,
      kSecUseAuthenticationContext: context,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let reference = result as? Data
    else {
      throw ViewerTestError.signingMetadataUnavailable
    }
    return reference
  }

  private func assertUnrelatedSignerCannotReadUseOrDelete(
    names: ViewerKeychainNames,
    certificatePersistentReference: Data
  ) {
    let context = LAContext()
    context.interactionNotAllowed = true
    func protected(_ query: [CFString: Any]) -> [CFString: Any] {
      var value = query
      value[kSecUseAuthenticationContext] = context
      return value
    }
    func genericPassword(_ account: String) -> [CFString: Any] {
      protected([
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: names.service,
        kSecAttrAccount: account,
        kSecAttrSynchronizable: false,
        kSecUseDataProtectionKeychain: false,
      ])
    }
    let privateKey = protected([
      kSecClass: kSecClassKey,
      kSecAttrApplicationTag: names.keyTagData,
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeyClass: kSecAttrKeyClassPrivate,
      kSecAttrSynchronizable: false,
      kSecUseDataProtectionKeychain: false,
    ])
    let certificate = protected([
      kSecClass: kSecClassCertificate,
      kSecMatchItemList: [certificatePersistentReference],
      kSecUseDataProtectionKeychain: false,
    ])

    for account in ["installation-id", "tls-metadata"] {
      var query = genericPassword(account)
      query[kSecReturnData] = true
      query[kSecMatchLimit] = kSecMatchLimitOne
      var result: CFTypeRef?
      XCTAssertNotEqual(
        SecItemCopyMatching(query as CFDictionary, &result),
        errSecSuccess,
        "An unrelated signer read \(account)."
      )
    }

    var privateKeyLookup = privateKey
    privateKeyLookup[kSecReturnRef] = true
    privateKeyLookup[kSecMatchLimit] = kSecMatchLimitOne
    var privateKeyResult: CFTypeRef?
    let privateKeyStatus = SecItemCopyMatching(
      privateKeyLookup as CFDictionary,
      &privateKeyResult
    )
    if privateKeyStatus == errSecSuccess, let privateKeyResult,
      CFGetTypeID(privateKeyResult) == SecKeyGetTypeID()
    {
      let key = privateKeyResult as! SecKey
      XCTAssertNil(
        SecKeyCreateSignature(
          key,
          .ecdsaSignatureMessageX962SHA256,
          Data("NearWire unrelated signer probe".utf8) as CFData,
          nil
        ),
        "An unrelated signer used the private key."
      )
    }
    XCTAssertNotEqual(
      privateKeyStatus,
      errSecSuccess,
      "An unrelated signer loaded the private key."
    )

    for query in [
      genericPassword("installation-id"),
      genericPassword("tls-metadata"),
      privateKey,
      certificate,
    ] {
      XCTAssertNotEqual(
        SecItemDelete(query as CFDictionary),
        errSecSuccess,
        "An unrelated signer deleted an exact identity record."
      )
    }
  }

  func testProductionKeychainConfigurationUsesZeroConfigurationMacKeychain() {
    XCTAssertFalse(ViewerKeychainNames.live.usesDataProtectionKeychain)
    XCTAssertEqual(ViewerKeychainNames.live.service, "com.nearwire.viewer.identity.v1")
    XCTAssertEqual(ViewerKeychainNames.live.keyTag, "com.nearwire.viewer.tls-key.v1")
  }

  func testExplicitTLSResetFailsClosedOnMalformedOwnedMetadata() throws {
    let names = ViewerKeychainNames.isolated()
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: names.service,
      kSecAttrAccount: "tls-metadata",
      kSecAttrSynchronizable: false,
      kSecUseDataProtectionKeychain: false,
    ]
    var add = query
    add[kSecValueData] = Data("malformed".utf8)
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    XCTAssertEqual(addStatus, errSecSuccess)
    let service = names.service
    addTeardownBlock {
      let cleanup: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: "tls-metadata",
        kSecAttrSynchronizable: false,
        kSecUseDataProtectionKeychain: false,
      ]
      SecItemDelete(cleanup as CFDictionary)
    }

    let store = ViewerIdentityStore(names: names)
    XCTAssertThrowsError(try store.resetTLSIdentity()) { error in
      XCTAssertEqual(error as? ViewerIdentityStoreError, .resetFailed)
    }

    var lookup = query
    lookup[kSecReturnData] = true
    lookup[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    XCTAssertEqual(SecItemCopyMatching(lookup as CFDictionary, &result), errSecSuccess)
    XCTAssertEqual(result as? Data, Data("malformed".utf8))
  }

  func testTLSResetPreservesCertificateWithoutOwnedMetadataReference() throws {
    let names = ViewerKeychainNames.isolated()
    let uniqueSerialBytes = Array(UUID().uuidString.utf8)
    let builder = ViewerCertificateBuilder(
      randomBytes: { count in Array(uniqueSerialBytes.prefix(count)) },
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
    let key = try builder.createEphemeralPrivateKey()
    let certificate = try builder.build(privateKey: key).certificate
    let label = "NearWire foreign test \(UUID().uuidString)"
    let add: [CFString: Any] = [
      kSecClass: kSecClassCertificate,
      kSecValueRef: certificate,
      kSecAttrLabel: label,
      kSecAttrSynchronizable: false,
      kSecUseDataProtectionKeychain: false,
      kSecReturnPersistentRef: true,
    ]
    var persistentResult: CFTypeRef?
    let addStatus = SecItemAdd(add as CFDictionary, &persistentResult)
    XCTAssertEqual(addStatus, errSecSuccess)
    var lookupResult: CFTypeRef?
    let lookupStatus = SecItemCopyMatching(
      [
        kSecClass: kSecClassCertificate,
        kSecMatchItemList: [certificate],
        kSecUseDataProtectionKeychain: false,
        kSecReturnPersistentRef: true,
        kSecMatchLimit: kSecMatchLimitOne,
      ] as CFDictionary, &lookupResult)
    XCTAssertEqual(lookupStatus, errSecSuccess)
    let persistentReference = try XCTUnwrap(lookupResult as? Data)
    let persistentQuery: [CFString: Any] = [
      kSecClass: kSecClassCertificate,
      kSecMatchItemList: [persistentReference],
      kSecUseDataProtectionKeychain: false,
    ]
    addTeardownBlock {
      let cleanup: [CFString: Any] = [
        kSecClass: kSecClassCertificate,
        kSecMatchItemList: [persistentReference],
        kSecUseDataProtectionKeychain: false,
      ]
      SecItemDelete(cleanup as CFDictionary)
    }

    XCTAssertThrowsError(try ViewerIdentityStore(names: names).resetTLSIdentity()) { error in
      XCTAssertEqual(error as? ViewerIdentityStoreError, .resetFailed)
    }

    var lookup = persistentQuery
    lookup[kSecReturnRef] = true
    lookup[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    XCTAssertEqual(SecItemCopyMatching(lookup as CFDictionary, &result), errSecSuccess)
    XCTAssertEqual(CFGetTypeID(result), SecCertificateGetTypeID())
  }

  func testAdmissionBudgetRejectsTheThirtyThirdSlotAndReleasesExactlyOnce() throws {
    let budget = ViewerAdmissionBudget()
    var reservations: [ViewerAdmissionBudget.Reservation] = []

    for _ in 0..<ViewerAdmissionManager.maximumAttempts {
      reservations.append(try XCTUnwrap(budget.reserve()))
    }
    XCTAssertEqual(budget.occupiedCount, 32)
    XCTAssertNil(budget.reserve())

    XCTAssertTrue(budget.release(reservations[0]))
    XCTAssertFalse(budget.release(reservations[0]))
    XCTAssertEqual(budget.occupiedCount, 31)
    XCTAssertNotNil(budget.reserve())
  }

  func testAdmissionCoreSendsViewerHelloOnceAndRejectsCoalescedPostHelloInput() throws {
    let sent = expectation(description: "Viewer Hello admitted")
    sent.expectedFulfillmentCount = 1
    let remoteHello = expectation(description: "App Hello decoded")
    remoteHello.expectedFulfillmentCount = 1
    let terminal = expectation(description: "Protocol violation closes core")
    terminal.expectedFulfillmentCount = 1
    let channel = FakeAdmissionChannel(
      supportsReceivePause: false,
      onSend: { _ in sent.fulfill() }
    )
    let viewerID = try EndpointID(rawValue: "viewer-test")
    let appID = try EndpointID(rawValue: "app-test")
    let core = try ViewerAdmissionConnectionCore(
      id: UUID(),
      viewerInstallationID: viewerID,
      onHello: { summary in
        XCTAssertEqual(summary.displayName, "Demo App")
        XCTAssertEqual(summary.installationAlias.count, 12)
        XCTAssertFalse(summary.installationAlias.contains("app-test"))
        remoteHello.fulfill()
      },
      onTerminal: { terminal.fulfill() }
    )
    try core.attach(channel)
    core.start()
    core.start()
    core.receive(.stateChanged(.ready))
    core.receive(.stateChanged(.ready))

    wait(for: [sent], timeout: 1)
    XCTAssertEqual(channel.startCount, 1)
    XCTAssertEqual(channel.sentPayloads.count, 1)

    let hello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .app,
      installationID: appID,
      displayName: "Demo App"
    )
    let frame = try WirePreHandshakeCodec().encode(hello)
    core.receive(.received(frame + frame))

    wait(for: [remoteHello, terminal], timeout: 1)
    XCTAssertEqual(channel.cancelCount, 1)
  }

  func testAdmissionManagerHandsOffProductionSDKEventRecordOffer() throws {
    let started = expectation(description: "Channel started")
    let viewerHelloSent = expectation(description: "Viewer Hello sent")
    let handedOff = expectation(description: "Production App Hello handed off")
    let channelClosed = expectation(description: "Handed-off channel closed at shutdown")
    let retainedHandle = LockedHandleBox()
    let handoffOwner = FakeAdmissionHandoffOwner { handle in
      retainedHandle.set(handle)
      handedOff.fulfill()
    }
    let channel = FakeAdmissionChannel(
      onSend: { _ in viewerHelloSent.fulfill() },
      onStart: { started.fulfill() },
      onCancel: { channelClosed.fulfill() }
    )
    let incoming = FakeIncomingConnection(channel: channel)
    let manager = ViewerAdmissionManager(
      onPending: { _ in },
      handoffOwner: handoffOwner
    )
    let generation = UUID()
    manager.activateGeneration(generation)
    manager.admit(
      incoming,
      generation: generation,
      viewerInstallationID: try EndpointID(rawValue: "viewer-production-offer")
    )

    wait(for: [started], timeout: 1)
    incoming.emit(.stateChanged(.ready))
    wait(for: [viewerHelloSent], timeout: 1)

    let oneMiBEventLimits = try EventValidationLimits(
      maximumEncodedContentBytes: 1_024 * 1_024,
      maximumEncodedModelBytes: 4_259_840
    )
    let peerOffer = try WireEventRecord.maximumDeterministicEncodedByteCount(
      eventLimits: oneMiBEventLimits
    )
    XCTAssertGreaterThan(peerOffer, 1_024 * 1_024)
    let peerFrameLimits = try WireFrameLimits(
      maximumControlPayloadBytes: WireFrameLimits.default.maximumControlPayloadBytes,
      maximumEventPayloadBytes: peerOffer
    )
    let peerLimits = try WireProtocolLimits(
      frame: peerFrameLimits,
      maximumEventBytes: peerOffer,
      eventValidationLimits: oneMiBEventLimits
    )
    let appHello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .app,
      installationID: EndpointID(rawValue: "production-sdk-app"),
      maximumEventBytes: peerOffer,
      displayName: "Production SDK App",
      limits: peerLimits
    )
    let frame = try WirePreHandshakeCodec(limits: peerLimits).encode(appHello)
    incoming.emit(.received(frame))

    wait(for: [handedOff], timeout: 1)
    let handle = try XCTUnwrap(retainedHandle.value)
    let context = try handle.connectionCore.pendingSessionContext()
    XCTAssertEqual(context.appHello.displayName, "Production SDK App")
    XCTAssertEqual(context.appHello.maximumEventBytes, peerOffer)
    XCTAssertEqual(
      context.negotiation.maximumEventBytes,
      peerOffer
    )
    XCTAssertEqual(channel.cancelCount, 0)
    manager.stop()
    wait(for: [channelClosed], timeout: 1)
  }

  func testAdmissionCoreRejectsViewerRoleWithoutPublishingAppSummary() throws {
    let sent = expectation(description: "Viewer Hello admitted")
    let terminal = expectation(description: "Wrong role terminates admission")
    let cancelled = expectation(description: "Wrong-role channel cancelled")
    let summary = expectation(description: "No App summary")
    summary.isInverted = true
    let channel = FakeAdmissionChannel(
      onSend: { _ in sent.fulfill() },
      onCancel: { cancelled.fulfill() }
    )
    let core = try ViewerAdmissionConnectionCore(
      id: UUID(),
      viewerInstallationID: EndpointID(rawValue: "viewer-test"),
      onHello: { _ in summary.fulfill() },
      onTerminal: { terminal.fulfill() }
    )
    try core.attach(channel)
    core.start()
    core.receive(.stateChanged(.ready))
    wait(for: [sent], timeout: 1)

    let wrongRole = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .viewer,
      installationID: EndpointID(rawValue: "other-viewer")
    )
    core.receive(.received(try WirePreHandshakeCodec().encode(wrongRole)))

    wait(for: [terminal, cancelled, summary], timeout: 0.3)
    XCTAssertEqual(channel.cancelCount, 1)
  }

  func testAdmissionCoreBackpressuresReceiveUntilHelloProcessingReturns() throws {
    let viewerHelloSent = expectation(description: "Viewer Hello sent")
    let helloProcessingEntered = expectation(description: "Hello processing entered")
    let allowHelloProcessing = DispatchSemaphore(value: 0)
    let receiveReturned = DispatchSemaphore(value: 0)
    let channel = FakeAdmissionChannel(onSend: { _ in viewerHelloSent.fulfill() })
    let core = try ViewerAdmissionConnectionCore(
      id: UUID(),
      viewerInstallationID: EndpointID(rawValue: "viewer-test"),
      onHello: { _ in
        helloProcessingEntered.fulfill()
        _ = allowHelloProcessing.wait(timeout: .now() + 2)
      },
      onTerminal: {}
    )
    try core.attach(channel)
    core.start()
    core.receive(.stateChanged(.ready))
    wait(for: [viewerHelloSent], timeout: 1)
    let frame = try makeAppHelloFrame(installationID: "backpressured-app")

    DispatchQueue.global().async {
      core.receive(.received(frame))
      receiveReturned.signal()
    }
    wait(for: [helloProcessingEntered], timeout: 1)
    XCTAssertEqual(receiveReturned.wait(timeout: .now() + 0.02), .timedOut)

    allowHelloProcessing.signal()
    XCTAssertEqual(receiveReturned.wait(timeout: .now() + 1), .success)
    core.requestCancellation()
  }

  @MainActor
  func testPendingCoalescerYieldsBetweenSnapshotsAndDropsDeactivatedGeneration() async {
    let first = ViewerPendingAppSummary.fixture(name: "First")
    let latest = ViewerPendingAppSummary.fixture(name: "Latest")
    let stale = ViewerPendingAppSummary.fixture(name: "Stale")
    let heartbeat = expectation(description: "MainActor heartbeat")
    let latestDelivered = expectation(description: "Latest snapshot delivered")
    let order = LockedStringSequence()
    let coalescerBox = LockedCoalescerBox()
    let coalescer = ViewerPendingCoalescer { pending in
      if pending == [first] {
        order.append("first")
        coalescerBox.value?.submit([latest])
        Task { @MainActor in
          order.append("heartbeat")
          heartbeat.fulfill()
        }
      } else if pending == [latest] {
        order.append("latest")
        latestDelivered.fulfill()
      }
    }
    coalescerBox.set(coalescer)
    coalescer.submit([first])
    await fulfillment(of: [heartbeat, latestDelivered], timeout: 1)
    XCTAssertEqual(order.values, ["first", "heartbeat", "latest"])

    let staleDeliveries = LockedTestCounter()
    let oldGeneration = ViewerPendingCoalescer { _ in staleDeliveries.increment() }
    oldGeneration.submit([stale])
    oldGeneration.deactivate()
    await Task.yield()
    await Task.yield()
    XCTAssertEqual(staleDeliveries.value, 0)
  }

  func testAdmissionManagerAutomaticallyHandsOffAndPlaceholderClosesCore() throws {
    let started = expectation(description: "Channel started")
    let viewerHelloSent = expectation(description: "Viewer Hello sent")
    let cancelled = expectation(description: "Placeholder closed accepted handoff")
    let channel = FakeAdmissionChannel(
      onSend: { _ in viewerHelloSent.fulfill() },
      onStart: { started.fulfill() },
      onCancel: { cancelled.fulfill() }
    )
    let incoming = FakeIncomingConnection(channel: channel)
    let pendingUpdates = LockedTestCounter()
    let manager = ViewerAdmissionManager(
      onPending: { summaries in
        if !summaries.isEmpty { pendingUpdates.increment() }
      }
    )
    let generation = UUID()
    manager.activateGeneration(generation)
    manager.admit(
      incoming,
      generation: generation,
      viewerInstallationID: try EndpointID(rawValue: "viewer-test")
    )

    wait(for: [started], timeout: 1)
    incoming.emit(.stateChanged(.ready))
    wait(for: [viewerHelloSent], timeout: 1)
    incoming.emit(.received(try makeAppHelloFrame(installationID: "app-auto")))

    wait(for: [cancelled], timeout: 1)
    XCTAssertEqual(manager.occupiedCount, 0)
    XCTAssertEqual(channel.cancelCount, 1)
    XCTAssertEqual(pendingUpdates.value, 0)
  }

  func testAdmissionManagerSnapshotsApprovalPolicyAndHandsOffSameCore() throws {
    let started = expectation(description: "Channel started")
    let viewerHelloSent = expectation(description: "Viewer Hello sent")
    let pendingUpdated = expectation(description: "Pending approval published")
    let handedOff = expectation(description: "Attempt handed off")
    let channelClosed = expectation(description: "Handed-off channel closed at shutdown")
    let retainedHandle = LockedHandleBox()
    let pendingSummary = LockedSummaryBox()
    let handoffOwner = FakeAdmissionHandoffOwner { handle in
      retainedHandle.set(handle)
      handedOff.fulfill()
    }
    let channel = FakeAdmissionChannel(
      onSend: { _ in viewerHelloSent.fulfill() },
      onStart: { started.fulfill() },
      onCancel: { channelClosed.fulfill() }
    )
    let incoming = FakeIncomingConnection(channel: channel)
    let manager = ViewerAdmissionManager(
      onPending: { summaries in
        guard let summary = summaries.first else { return }
        pendingSummary.set(summary)
        pendingUpdated.fulfill()
      },
      handoffOwner: handoffOwner
    )
    manager.setRequiresApproval(true)
    let generation = UUID()
    manager.activateGeneration(generation)
    manager.admit(
      incoming,
      generation: generation,
      viewerInstallationID: try EndpointID(rawValue: "viewer-test")
    )

    wait(for: [started], timeout: 1)
    incoming.emit(.stateChanged(.ready))
    wait(for: [viewerHelloSent], timeout: 1)
    incoming.emit(.received(try makeAppHelloFrame(installationID: "app-policy")))
    wait(for: [pendingUpdated], timeout: 1)

    manager.setRequiresApproval(false)
    XCTAssertEqual(manager.occupiedCount, 1)
    XCTAssertEqual(channel.cancelCount, 0)
    manager.accept(try XCTUnwrap(pendingSummary.value).id)

    wait(for: [handedOff], timeout: 1)
    XCTAssertEqual(manager.occupiedCount, 1)
    manager.stop()
    manager.stop()
    wait(for: [channelClosed], timeout: 1)
    XCTAssertEqual(channel.cancelCount, 1)
  }

  func testAdmissionDeadlineCoversSilentAndPartialPeersInBothPolicies() throws {
    struct TestCase {
      let requiresApproval: Bool
      let sendsPartialHello: Bool
    }
    let cases = [
      TestCase(requiresApproval: false, sendsPartialHello: false),
      TestCase(requiresApproval: true, sendsPartialHello: false),
      TestCase(requiresApproval: false, sendsPartialHello: true),
      TestCase(requiresApproval: true, sendsPartialHello: true),
    ]

    for (index, testCase) in cases.enumerated() {
      let scheduler = ManualAdmissionScheduler()
      let started = expectation(description: "Channel \(index) started")
      let cancelled = expectation(description: "Channel \(index) timed out")
      let viewerHelloSent =
        testCase.sendsPartialHello
        ? expectation(description: "Viewer Hello \(index) sent") : nil
      let channel = FakeAdmissionChannel(
        onSend: { _ in viewerHelloSent?.fulfill() },
        onStart: { started.fulfill() },
        onCancel: { cancelled.fulfill() }
      )
      let incoming = FakeIncomingConnection(channel: channel)
      let manager = ViewerAdmissionManager(
        onPending: { _ in },
        deadlineNanoseconds: 10_000,
        scheduler: scheduler.scheduler
      )
      manager.setRequiresApproval(testCase.requiresApproval)
      let generation = UUID()
      manager.activateGeneration(generation)
      manager.admit(
        incoming,
        generation: generation,
        viewerInstallationID: try EndpointID(rawValue: "viewer-test")
      )
      wait(for: [started], timeout: 1)
      scheduler.waitUntilScheduled()

      if testCase.sendsPartialHello {
        incoming.emit(.stateChanged(.ready))
        wait(for: [try XCTUnwrap(viewerHelloSent)], timeout: 1)
        let frame = try makeAppHelloFrame(installationID: "app-partial-\(index)")
        incoming.emit(.received(Data(frame.prefix(frame.count / 2))))
      }

      scheduler.advance(by: 10_000)
      wait(for: [cancelled], timeout: 1)
      XCTAssertEqual(manager.occupiedCount, 0)
      XCTAssertEqual(channel.cancelCount, 1)
      if !testCase.sendsPartialHello { XCTAssertTrue(channel.sentPayloads.isEmpty) }
    }

    XCTAssertEqual(ViewerAdmissionManager.deadlineNanoseconds, 10_000_000_000)
  }

  func testOriginalAdmissionDeadlineContinuesWhileApprovalIsPending() throws {
    let scheduler = ManualAdmissionScheduler()
    let started = expectation(description: "Channel started")
    let viewerHelloSent = expectation(description: "Viewer Hello sent")
    let pendingPublished = expectation(description: "Approval row published")
    let cancelled = expectation(description: "Original deadline cancelled pending attempt")
    let channel = FakeAdmissionChannel(
      onSend: { _ in viewerHelloSent.fulfill() },
      onStart: { started.fulfill() },
      onCancel: { cancelled.fulfill() }
    )
    let incoming = FakeIncomingConnection(channel: channel)
    let manager = ViewerAdmissionManager(
      onPending: { summaries in
        if !summaries.isEmpty { pendingPublished.fulfill() }
      },
      deadlineNanoseconds: 10_000,
      scheduler: scheduler.scheduler
    )
    manager.setRequiresApproval(true)
    let generation = UUID()
    manager.activateGeneration(generation)
    manager.admit(
      incoming,
      generation: generation,
      viewerInstallationID: try EndpointID(rawValue: "viewer-test")
    )
    wait(for: [started], timeout: 1)
    scheduler.waitUntilScheduled()
    incoming.emit(.stateChanged(.ready))
    wait(for: [viewerHelloSent], timeout: 1)
    incoming.emit(.received(try makeAppHelloFrame(installationID: "app-pending-timeout")))
    wait(for: [pendingPublished], timeout: 1)

    scheduler.advance(by: 10_000)
    wait(for: [cancelled], timeout: 1)
    XCTAssertEqual(manager.occupiedCount, 0)
    XCTAssertEqual(channel.cancelCount, 1)
  }

  func testAcceptAndTimeoutChooseExactlyOneTerminalWinnerInBothOrders() throws {
    do {
      let scheduler = ManualAdmissionScheduler()
      let pending = expectation(description: "Pending before accept")
      let handedOff = expectation(description: "Accept wins")
      let summary = LockedSummaryBox()
      let handle = LockedHandleBox()
      let handoffOwner = FakeAdmissionHandoffOwner {
        handle.set($0)
        handedOff.fulfill()
      }
      let channel = FakeAdmissionChannel()
      let incoming = FakeIncomingConnection(channel: channel)
      let manager = ViewerAdmissionManager(
        onPending: { values in
          guard let value = values.first else { return }
          summary.set(value)
          pending.fulfill()
        },
        handoffOwner: handoffOwner,
        deadlineNanoseconds: 100,
        scheduler: scheduler.scheduler
      )
      manager.setRequiresApproval(true)
      let generation = UUID()
      manager.activateGeneration(generation)
      manager.admit(
        incoming,
        generation: generation,
        viewerInstallationID: try EndpointID(rawValue: "viewer-test")
      )
      scheduler.waitUntilScheduled()
      incoming.emit(.stateChanged(.ready))
      incoming.emit(.received(try makeAppHelloFrame(installationID: "accept-wins")))
      wait(for: [pending], timeout: 1)

      manager.accept(try XCTUnwrap(summary.value).id)
      wait(for: [handedOff], timeout: 1)
      scheduler.advance(by: 100)
      XCTAssertEqual(manager.occupiedCount, 1)
      XCTAssertEqual(channel.cancelCount, 0)
      handle.value?.cancel()
      _ = manager.stop()
    }

    do {
      let scheduler = ManualAdmissionScheduler()
      let pending = expectation(description: "Pending before timeout")
      let cancelled = expectation(description: "Timeout wins")
      let handedOff = expectation(description: "No handoff after timeout")
      handedOff.isInverted = true
      let summary = LockedSummaryBox()
      let channel = FakeAdmissionChannel(onCancel: { cancelled.fulfill() })
      let incoming = FakeIncomingConnection(channel: channel)
      let handoffOwner = FakeAdmissionHandoffOwner { _ in handedOff.fulfill() }
      let manager = ViewerAdmissionManager(
        onPending: { values in
          guard let value = values.first else { return }
          summary.set(value)
          pending.fulfill()
        },
        handoffOwner: handoffOwner,
        deadlineNanoseconds: 100,
        scheduler: scheduler.scheduler
      )
      manager.setRequiresApproval(true)
      let generation = UUID()
      manager.activateGeneration(generation)
      manager.admit(
        incoming,
        generation: generation,
        viewerInstallationID: try EndpointID(rawValue: "viewer-test")
      )
      scheduler.waitUntilScheduled()
      incoming.emit(.stateChanged(.ready))
      incoming.emit(.received(try makeAppHelloFrame(installationID: "timeout-wins")))
      wait(for: [pending], timeout: 1)

      scheduler.advance(by: 100)
      wait(for: [cancelled], timeout: 1)
      manager.accept(try XCTUnwrap(summary.value).id)
      wait(for: [handedOff], timeout: 0.05)
      XCTAssertEqual(manager.occupiedCount, 0)
      XCTAssertEqual(channel.cancelCount, 1)
      _ = manager.stop()
    }
  }

  func testEveryTimeoutCompetitorSelectsOneWinnerInBothOrders() async throws {
    enum Competitor: CaseIterable {
      case reject
      case pause
      case replacement
      case stop
      case channelTermination
    }

    for competitor in Competitor.allCases {
      for competitorWins in [true, false] {
        let scheduler = ManualAdmissionScheduler()
        let pending = expectation(description: "Pending \(competitor) \(competitorWins)")
        let expectsCancellation = !(competitorWins && competitor == .channelTermination)
        let cancelled =
          expectsCancellation
          ? expectation(description: "Cancelled \(competitor) \(competitorWins)") : nil
        let summary = LockedSummaryBox()
        let handoffs = LockedTestCounter()
        let channel = FakeAdmissionChannel(onCancel: { cancelled?.fulfill() })
        let incoming = FakeIncomingConnection(channel: channel)
        let owner = FakeAdmissionHandoffOwner { _ in handoffs.increment() }
        let manager = ViewerAdmissionManager(
          onPending: { values in
            guard let value = values.first else { return }
            summary.set(value)
            pending.fulfill()
          },
          handoffOwner: owner,
          deadlineNanoseconds: 100,
          scheduler: scheduler.scheduler
        )
        manager.setRequiresApproval(true)
        let generation = UUID()
        manager.activateGeneration(generation)
        manager.admit(
          incoming,
          generation: generation,
          viewerInstallationID: try EndpointID(rawValue: "viewer-test")
        )
        scheduler.waitUntilScheduled()
        incoming.emit(.stateChanged(.ready))
        incoming.emit(
          .received(
            try makeAppHelloFrame(
              installationID: "competitor-\(competitor)-\(competitorWins)"
            )
          )
        )
        await fulfillment(of: [pending], timeout: 1)
        let summaryID = try XCTUnwrap(summary.value).id

        let applyCompetitor = {
          switch competitor {
          case .reject:
            manager.reject(summaryID)
          case .pause:
            manager.setPaused(true)
          case .replacement:
            manager.cancelGeneration(generation)
          case .stop:
            _ = manager.stop()
          case .channelTermination:
            incoming.emit(
              .terminated(
                SecureTransportError(
                  code: .driverFailure,
                  message: "Safe test termination",
                  disposition: .connectionTerminal
                )
              )
            )
          }
        }

        if competitorWins {
          applyCompetitor()
          if competitor != .channelTermination {
            await fulfillment(of: [try XCTUnwrap(cancelled)], timeout: 1)
          }
          scheduler.advance(by: 100)
        } else {
          scheduler.advance(by: 100)
          await fulfillment(of: [try XCTUnwrap(cancelled)], timeout: 1)
          applyCompetitor()
        }

        let receipt = manager.stop()
        let cleanupOutcome = await receipt.wait(timeoutNanoseconds: 1_000_000_000)
        XCTAssertEqual(cleanupOutcome, .completed)
        XCTAssertEqual(manager.occupiedCount, 0)
        XCTAssertEqual(handoffs.value, 0)
        XCTAssertEqual(
          channel.cancelCount,
          competitorWins && competitor == .channelTermination ? 0 : 1
        )
      }
    }
  }

  func testAdmissionManagerRejectsThirtyThirdConnectionBeforeClaimAcrossGenerations() throws {
    let allStarted = expectation(description: "Thirty-two channels started")
    allStarted.expectedFulfillmentCount = ViewerAdmissionManager.maximumAttempts
    let allCancelled = expectation(description: "Thirty-two channels cancelled")
    allCancelled.expectedFulfillmentCount = ViewerAdmissionManager.maximumAttempts
    let manager = ViewerAdmissionManager(onPending: { _ in })
    let firstGeneration = UUID()
    let secondGeneration = UUID()
    manager.activateGeneration(firstGeneration)
    manager.activateGeneration(secondGeneration)
    let viewerID = try EndpointID(rawValue: "viewer-test")
    let incoming = (0...ViewerAdmissionManager.maximumAttempts).map { _ in
      FakeIncomingConnection(
        channel: FakeAdmissionChannel(
          onStart: { allStarted.fulfill() },
          onCancel: { allCancelled.fulfill() }
        )
      )
    }

    for index in 0..<ViewerAdmissionManager.maximumAttempts {
      manager.admit(
        incoming[index],
        generation: index.isMultiple(of: 2) ? firstGeneration : secondGeneration,
        viewerInstallationID: viewerID
      )
    }
    wait(for: [allStarted], timeout: 2)
    XCTAssertEqual(manager.occupiedCount, 32)

    manager.admit(
      incoming[ViewerAdmissionManager.maximumAttempts],
      generation: secondGeneration,
      viewerInstallationID: viewerID
    )
    XCTAssertEqual(incoming[ViewerAdmissionManager.maximumAttempts].claimCount, 0)
    XCTAssertEqual(manager.occupiedCount, 32)

    manager.stop()
    XCTAssertEqual(manager.occupiedCount, ViewerAdmissionManager.maximumAttempts)
    wait(for: [allCancelled], timeout: 2)
  }

  func testPauseCancelsExistingAttemptsAndRejectsLaterArrivalsBeforeClaim() throws {
    let started = expectation(description: "Existing channel started")
    let cancelled = expectation(description: "Existing channel cancelled")
    let manager = ViewerAdmissionManager(onPending: { _ in })
    let existing = FakeIncomingConnection(
      channel: FakeAdmissionChannel(
        onStart: { started.fulfill() },
        onCancel: { cancelled.fulfill() }
      )
    )
    let later = FakeIncomingConnection(channel: FakeAdmissionChannel())
    let viewerID = try EndpointID(rawValue: "viewer-test")
    let generation = UUID()
    manager.activateGeneration(generation)
    manager.admit(existing, generation: generation, viewerInstallationID: viewerID)
    wait(for: [started], timeout: 1)

    manager.setPaused(true)
    wait(for: [cancelled], timeout: 1)
    XCTAssertEqual(manager.occupiedCount, 0)
    manager.admit(later, generation: generation, viewerInstallationID: viewerID)
    XCTAssertEqual(later.claimCount, 0)
  }

  func testWorkspaceMutationLeaseExcludesAttemptsAndRejectsNewAdmissionUntilRelease() throws {
    let manager = ViewerAdmissionManager(onPending: { _ in })
    let generation = UUID()
    let viewerID = try EndpointID(rawValue: "viewer-workspace-lease")
    manager.activateGeneration(generation)

    let lease = try XCTUnwrap(manager.claimWorkspaceMutation())
    XCTAssertNil(manager.claimWorkspaceMutation())
    let rejected = FakeIncomingConnection(channel: FakeAdmissionChannel())
    manager.admit(rejected, generation: generation, viewerInstallationID: viewerID)
    XCTAssertEqual(rejected.claimCount, 0)
    XCTAssertEqual(rejected.rejectionCount, 1)

    lease.release()
    let admitted = FakeIncomingConnection(channel: FakeAdmissionChannel())
    manager.admit(admitted, generation: generation, viewerInstallationID: viewerID)
    XCTAssertEqual(admitted.claimCount, 1)
    XCTAssertNil(manager.claimWorkspaceMutation())
    _ = manager.stop()
  }

  func testListenerGenerationCancellationDoesNotAffectOtherGeneration() async throws {
    let bothStarted = expectation(description: "Both generation channels started")
    bothStarted.expectedFulfillmentCount = 2
    let oldCancelled = expectation(description: "Old generation channel cancelled")
    let newCancelled = expectation(description: "New generation channel cancelled at shutdown")
    let oldIncoming = FakeIncomingConnection(
      channel: FakeAdmissionChannel(
        onStart: { bothStarted.fulfill() },
        onCancel: { oldCancelled.fulfill() }
      )
    )
    let newIncoming = FakeIncomingConnection(
      channel: FakeAdmissionChannel(
        onStart: { bothStarted.fulfill() },
        onCancel: { newCancelled.fulfill() }
      )
    )
    let oldGeneration = UUID()
    let newGeneration = UUID()
    let manager = ViewerAdmissionManager(onPending: { _ in })
    let viewerID = try EndpointID(rawValue: "viewer-test")
    manager.activateGeneration(oldGeneration)
    manager.activateGeneration(newGeneration)
    manager.admit(oldIncoming, generation: oldGeneration, viewerInstallationID: viewerID)
    manager.admit(newIncoming, generation: newGeneration, viewerInstallationID: viewerID)
    await fulfillment(of: [bothStarted], timeout: 1)

    manager.cancelGeneration(oldGeneration)
    await fulfillment(of: [oldCancelled], timeout: 1)
    await waitForAdmissionOccupancy(1, in: manager)
    XCTAssertEqual(newIncoming.channel.cancelCount, 0)

    let cleanup = manager.stop()
    await fulfillment(of: [newCancelled], timeout: 1)
    let outcome = await cleanup.wait(timeoutNanoseconds: 1_000_000_000)
    XCTAssertEqual(outcome, .completed)
    XCTAssertEqual(manager.occupiedCount, 0)
  }

  func testClaimInProgressCannotSurviveGenerationCancellationOrPauseResume() async throws {
    enum CancellationMode: String {
      case generation
      case pauseResume
    }

    for mode in [CancellationMode.generation, .pauseResume] {
      let enteredClaim = expectation(description: "\(mode.rawValue) entered claim")
      let admissionReturned = expectation(description: "\(mode.rawValue) admission returned")
      let channelCancelled = expectation(description: "\(mode.rawValue) channel cancelled")
      let releaseClaim = DispatchSemaphore(value: 0)
      let channel = FakeAdmissionChannel(onCancel: { channelCancelled.fulfill() })
      let incoming = FakeIncomingConnection(
        channel: channel,
        beforeClaim: {
          enteredClaim.fulfill()
          releaseClaim.wait()
        }
      )
      let manager = ViewerAdmissionManager(onPending: { _ in })
      let generation = UUID()
      manager.activateGeneration(generation)
      let viewerID = try EndpointID(rawValue: "viewer-test")

      DispatchQueue.global().async {
        manager.admit(incoming, generation: generation, viewerInstallationID: viewerID)
        admissionReturned.fulfill()
      }
      await fulfillment(of: [enteredClaim], timeout: 1)
      XCTAssertEqual(manager.occupiedCount, 1)

      switch mode {
      case .generation:
        manager.cancelGeneration(generation)
      case .pauseResume:
        manager.setPaused(true)
        manager.setPaused(false)
      }
      XCTAssertEqual(manager.occupiedCount, 1)
      releaseClaim.signal()

      await fulfillment(of: [admissionReturned, channelCancelled], timeout: 1)
      XCTAssertEqual(channel.startCount, 0)
      XCTAssertEqual(channel.cancelCount, 1)
      XCTAssertEqual(incoming.claimCount, 1)
      let receipt = manager.stop()
      let outcome = await receipt.wait(timeoutNanoseconds: 1_000_000_000)
      XCTAssertEqual(outcome, .completed)
      XCTAssertEqual(manager.occupiedCount, 0)
    }
  }

  func testListenerAdmissionIngressBoundsBurstBeforeMainActorWork() async throws {
    let allStarted = expectation(description: "Thirty-two ingress channels started")
    allStarted.expectedFulfillmentCount = ViewerAdmissionManager.maximumAttempts
    let allCancelled = expectation(description: "Thirty-two ingress channels cancelled")
    allCancelled.expectedFulfillmentCount = ViewerAdmissionManager.maximumAttempts
    let manager = ViewerAdmissionManager(onPending: { _ in })
    let ingress = ViewerListenerAdmissionIngress()
    let generation = UUID()
    let viewerID = try EndpointID(rawValue: "viewer-test")
    manager.activateGeneration(generation)
    ingress.activate(
      manager: manager,
      generation: generation,
      viewerInstallationID: viewerID
    )
    let incoming = (0...ViewerAdmissionManager.maximumAttempts).map { _ in
      FakeIncomingConnection(
        channel: FakeAdmissionChannel(
          onStart: { allStarted.fulfill() },
          onCancel: { allCancelled.fulfill() }
        )
      )
    }

    for connection in incoming { ingress.receive(connection) }
    await fulfillment(of: [allStarted], timeout: 2)
    XCTAssertEqual(manager.occupiedCount, ViewerAdmissionManager.maximumAttempts)
    XCTAssertEqual(incoming.last?.claimCount, 0)
    XCTAssertEqual(incoming.last?.rejectionCount, 1)

    let receipt = manager.stop()
    await fulfillment(of: [allCancelled], timeout: 2)
    let outcome = await receipt.wait(timeoutNanoseconds: 1_000_000_000)
    XCTAssertEqual(outcome, .completed)
    XCTAssertEqual(manager.occupiedCount, 0)
  }

  func testCleanupReceiptCompletesOrTimesOutWithoutReopeningAdmission() async throws {
    let scheduler = ManualAdmissionScheduler()
    let cancellationGate = AsyncTestGate()
    let channel = FakeAdmissionChannel(
      cancelOperation: { await cancellationGate.wait() }
    )
    let incoming = FakeIncomingConnection(channel: channel)
    let manager = ViewerAdmissionManager(
      onPending: { _ in },
      scheduler: scheduler.scheduler
    )
    let generation = UUID()
    manager.activateGeneration(generation)
    manager.admit(
      incoming,
      generation: generation,
      viewerInstallationID: try EndpointID(rawValue: "viewer-test")
    )
    scheduler.waitUntilScheduled()

    let receipt = manager.stop()
    let wait = Task {
      await receipt.wait(timeoutNanoseconds: 100, scheduler: scheduler.scheduler)
    }
    scheduler.waitUntilScheduled()
    scheduler.advance(by: 100)
    let timeoutOutcome = await wait.value
    XCTAssertEqual(timeoutOutcome, .timedOut)
    XCTAssertEqual(manager.occupiedCount, 1)

    let rejected = FakeIncomingConnection(channel: FakeAdmissionChannel())
    manager.admit(
      rejected,
      generation: generation,
      viewerInstallationID: try EndpointID(rawValue: "viewer-test")
    )
    XCTAssertEqual(rejected.rejectionCount, 1)
    XCTAssertEqual(rejected.claimCount, 0)

    cancellationGate.open()
    let final = await receipt.wait(timeoutNanoseconds: 1_000_000_000)
    XCTAssertEqual(final, .completed)
    XCTAssertEqual(channel.cancelCount, 1)
    XCTAssertEqual(manager.occupiedCount, 0)
    XCTAssertTrue(receipt === manager.stop())
  }

  func testStopReceiptOwnsCleanupAlreadyStartedByEveryAdmissionPolicy() async throws {
    enum TerminalAction: CaseIterable {
      case pause
      case reject
      case timeout
      case replacement
    }

    for action in TerminalAction.allCases {
      let scheduler = ManualAdmissionScheduler()
      let cancellationGate = AsyncTestGate()
      let pending = expectation(description: "Pending row published for \(action)")
      let summary = LockedSummaryBox()
      let channel = FakeAdmissionChannel(cancelOperation: { await cancellationGate.wait() })
      let incoming = FakeIncomingConnection(channel: channel)
      let manager = ViewerAdmissionManager(
        onPending: { values in
          guard let value = values.first else { return }
          summary.set(value)
          pending.fulfill()
        },
        deadlineNanoseconds: 100,
        scheduler: scheduler.scheduler
      )
      manager.setRequiresApproval(true)
      let generation = UUID()
      manager.activateGeneration(generation)
      manager.admit(
        incoming,
        generation: generation,
        viewerInstallationID: try EndpointID(rawValue: "viewer-test")
      )
      scheduler.waitUntilScheduled()
      incoming.emit(.stateChanged(.ready))
      incoming.emit(.received(try makeAppHelloFrame(installationID: "policy-\(action)")))
      await fulfillment(of: [pending], timeout: 1)

      switch action {
      case .pause:
        manager.setPaused(true)
      case .reject:
        manager.reject(try XCTUnwrap(summary.value).id)
      case .timeout:
        scheduler.advance(by: 100)
      case .replacement:
        manager.cancelGeneration(generation)
      }
      cancellationGate.waitUntilEntered()

      let receipt = manager.stop()
      let boundedWait = Task {
        await receipt.wait(timeoutNanoseconds: 100, scheduler: scheduler.scheduler)
      }
      scheduler.waitUntilScheduled()
      scheduler.advance(by: 100)
      let timeoutOutcome = await boundedWait.value
      XCTAssertEqual(timeoutOutcome, .timedOut)
      XCTAssertEqual(manager.occupiedCount, 1)

      cancellationGate.open()
      let cleanupOutcome = await receipt.wait(timeoutNanoseconds: 1_000_000_000)
      XCTAssertEqual(cleanupOutcome, .completed)
      XCTAssertEqual(channel.cancelCount, 1)
      XCTAssertEqual(manager.occupiedCount, 0)
    }
  }

  func testStopReceiptRetainsClaimInProgressAndItsLateChannelCleanup() async throws {
    let scheduler = ManualAdmissionScheduler()
    let claimEntered = DispatchSemaphore(value: 0)
    let releaseClaim = DispatchSemaphore(value: 0)
    let cancellationGate = AsyncTestGate()
    let channel = FakeAdmissionChannel(cancelOperation: { await cancellationGate.wait() })
    let incoming = FakeIncomingConnection(
      channel: channel,
      beforeClaim: {
        claimEntered.signal()
        _ = releaseClaim.wait(timeout: .now() + 2)
      }
    )
    let manager = ViewerAdmissionManager(onPending: { _ in }, scheduler: scheduler.scheduler)
    let generation = UUID()
    manager.activateGeneration(generation)
    let admissionReturned = expectation(description: "Blocked admission returned")
    DispatchQueue.global().async {
      manager.admit(
        incoming,
        generation: generation,
        viewerInstallationID: try! EndpointID(rawValue: "viewer-test")
      )
      admissionReturned.fulfill()
    }
    XCTAssertEqual(claimEntered.wait(timeout: .now() + 1), .success)

    let receipt = manager.stop()
    let boundedWait = Task {
      await receipt.wait(timeoutNanoseconds: 100, scheduler: scheduler.scheduler)
    }
    scheduler.waitUntilScheduled()
    scheduler.advance(by: 100)
    let timeoutOutcome = await boundedWait.value
    XCTAssertEqual(timeoutOutcome, .timedOut)
    XCTAssertEqual(manager.occupiedCount, 1)

    releaseClaim.signal()
    cancellationGate.waitUntilEntered()
    cancellationGate.open()
    await fulfillment(of: [admissionReturned], timeout: 1)
    let cleanupOutcome = await receipt.wait(timeoutNanoseconds: 1_000_000_000)
    XCTAssertEqual(cleanupOutcome, .completed)
    XCTAssertEqual(channel.cancelCount, 1)
    XCTAssertEqual(manager.occupiedCount, 0)
  }

  func testStopReceiptIncludesAcceptedHandoffCleanup() async throws {
    let scheduler = ManualAdmissionScheduler()
    let shutdownGate = AsyncTestGate()
    let handedOff = expectation(description: "Connection handed off")
    let channel = FakeAdmissionChannel()
    let incoming = FakeIncomingConnection(channel: channel)
    let owner = FakeAdmissionHandoffOwner(
      onTransfer: { _ in handedOff.fulfill() },
      shutdownOperation: { await shutdownGate.wait() }
    )
    let manager = ViewerAdmissionManager(
      onPending: { _ in },
      handoffOwner: owner,
      scheduler: scheduler.scheduler
    )
    let generation = UUID()
    manager.activateGeneration(generation)
    manager.admit(
      incoming,
      generation: generation,
      viewerInstallationID: try EndpointID(rawValue: "viewer-test")
    )
    scheduler.waitUntilScheduled()
    incoming.emit(.stateChanged(.ready))
    incoming.emit(.received(try makeAppHelloFrame(installationID: "handoff-cleanup")))
    await fulfillment(of: [handedOff], timeout: 1)

    let receipt = manager.stop()
    shutdownGate.waitUntilEntered()
    let boundedWait = Task {
      await receipt.wait(timeoutNanoseconds: 100, scheduler: scheduler.scheduler)
    }
    scheduler.waitUntilScheduled()
    scheduler.advance(by: 100)
    let timeoutOutcome = await boundedWait.value
    XCTAssertEqual(timeoutOutcome, .timedOut)
    XCTAssertEqual(manager.occupiedCount, 1)

    shutdownGate.open()
    let cleanupOutcome = await receipt.wait(timeoutNanoseconds: 1_000_000_000)
    XCTAssertEqual(cleanupOutcome, .completed)
    XCTAssertEqual(channel.cancelCount, 1)
    XCTAssertEqual(manager.occupiedCount, 0)
  }

  func testCombinedAdmissionBoundIncludesCancellingAndPlaceholderOwnedConnections()
    async throws
  {
    enum RetainedMode: CaseIterable {
      case cancellation
      case placeholderHandoff
    }

    for mode in RetainedMode.allCases {
      let cleanupGate = AsyncTestGate()
      let allStarted = expectation(description: "All bounded channels started for \(mode)")
      allStarted.expectedFulfillmentCount = ViewerAdmissionManager.maximumAttempts
      let allCancelled = expectation(description: "All bounded channels cancelled for \(mode)")
      allCancelled.expectedFulfillmentCount = ViewerAdmissionManager.maximumAttempts
      let manager = ViewerAdmissionManager(onPending: { _ in })
      let generation = UUID()
      manager.activateGeneration(generation)
      let viewerID = try EndpointID(rawValue: "viewer-test")
      let incoming = (0...ViewerAdmissionManager.maximumAttempts).map { _ in
        FakeIncomingConnection(
          channel: FakeAdmissionChannel(
            onStart: { allStarted.fulfill() },
            onCancel: { allCancelled.fulfill() },
            cancelOperation: { await cleanupGate.wait() }
          )
        )
      }

      for index in 0..<ViewerAdmissionManager.maximumAttempts {
        manager.admit(incoming[index], generation: generation, viewerInstallationID: viewerID)
      }
      await fulfillment(of: [allStarted], timeout: 2)

      switch mode {
      case .cancellation:
        manager.setPaused(true)
        manager.setPaused(false)
      case .placeholderHandoff:
        for index in 0..<ViewerAdmissionManager.maximumAttempts {
          incoming[index].emit(.stateChanged(.ready))
          incoming[index].emit(
            .received(try makeAppHelloFrame(installationID: "bounded-handoff-\(index)"))
          )
        }
      }
      cleanupGate.waitUntilEntered(count: ViewerAdmissionManager.maximumAttempts)
      XCTAssertEqual(manager.occupiedCount, ViewerAdmissionManager.maximumAttempts)

      manager.admit(
        incoming[ViewerAdmissionManager.maximumAttempts],
        generation: generation,
        viewerInstallationID: viewerID
      )
      XCTAssertEqual(incoming[ViewerAdmissionManager.maximumAttempts].claimCount, 0)
      XCTAssertEqual(incoming[ViewerAdmissionManager.maximumAttempts].rejectionCount, 1)

      let receipt = manager.stop()
      cleanupGate.open()
      await fulfillment(of: [allCancelled], timeout: 2)
      let outcome = await receipt.wait(timeoutNanoseconds: 1_000_000_000)
      XCTAssertEqual(outcome, .completed)
      XCTAssertEqual(manager.occupiedCount, 0)
      XCTAssertEqual(
        incoming.dropLast().map(\.channel.cancelCount),
        Array(repeating: 1, count: ViewerAdmissionManager.maximumAttempts)
      )
    }
  }

  func testHandoffCapacityRecyclesAcrossWavesInOneRuntime() async throws {
    let firstWaveTransferred = expectation(description: "First handoff wave transferred")
    firstWaveTransferred.expectedFulfillmentCount = ViewerAdmissionManager.maximumAttempts
    let secondWaveTransferred = expectation(description: "Second handoff wave transferred")
    let recycledCount = 8
    secondWaveTransferred.expectedFulfillmentCount = recycledCount
    let handles = LockedHandleCollection()
    let owner = FakeAdmissionHandoffOwner(
      onTransfer: { handle in
        let count = handles.append(handle)
        if count <= ViewerAdmissionManager.maximumAttempts {
          firstWaveTransferred.fulfill()
        } else {
          secondWaveTransferred.fulfill()
        }
      }
    )
    let manager = ViewerAdmissionManager(onPending: { _ in }, handoffOwner: owner)
    let generation = UUID()
    let viewerID = try EndpointID(rawValue: "viewer-test")
    manager.activateGeneration(generation)

    let firstWave = (0..<ViewerAdmissionManager.maximumAttempts).map { index in
      FakeIncomingConnection(channel: FakeAdmissionChannel())
    }
    for (index, incoming) in firstWave.enumerated() {
      manager.admit(incoming, generation: generation, viewerInstallationID: viewerID)
      incoming.emit(.stateChanged(.ready))
      incoming.emit(
        .received(try makeAppHelloFrame(installationID: "recycle-first-\(index)"))
      )
    }
    await fulfillment(of: [firstWaveTransferred], timeout: 2)
    XCTAssertEqual(manager.occupiedCount, ViewerAdmissionManager.maximumAttempts)

    for handle in handles.values.prefix(recycledCount) {
      await handle.cancelAndWait()
    }
    XCTAssertEqual(
      manager.occupiedCount,
      ViewerAdmissionManager.maximumAttempts - recycledCount
    )

    let secondWave = (0..<recycledCount).map { _ in
      FakeIncomingConnection(channel: FakeAdmissionChannel())
    }
    for (index, incoming) in secondWave.enumerated() {
      manager.admit(incoming, generation: generation, viewerInstallationID: viewerID)
      incoming.emit(.stateChanged(.ready))
      incoming.emit(
        .received(try makeAppHelloFrame(installationID: "recycle-second-\(index)"))
      )
    }
    await fulfillment(of: [secondWaveTransferred], timeout: 2)
    XCTAssertEqual(manager.occupiedCount, ViewerAdmissionManager.maximumAttempts)

    let overflow = FakeIncomingConnection(channel: FakeAdmissionChannel())
    manager.admit(overflow, generation: generation, viewerInstallationID: viewerID)
    XCTAssertEqual(overflow.claimCount, 0)
    XCTAssertEqual(overflow.rejectionCount, 1)

    let receipt = manager.stop()
    let outcome = await receipt.wait(timeoutNanoseconds: 1_000_000_000)
    XCTAssertEqual(outcome, .completed)
    XCTAssertEqual(manager.occupiedCount, 0)
    XCTAssertEqual(
      (firstWave + secondWave).map(\.channel.cancelCount),
      Array(repeating: 1, count: ViewerAdmissionManager.maximumAttempts + recycledCount)
    )
  }

  @MainActor
  func testIdentityResetWaitsForAdmissionCleanupReceipt() async throws {
    enum ResetMode: String {
      case tls
      case full
    }

    for mode in [ResetMode.tls, .full] {
      let cleanupGate = AsyncTestGate()
      let resetCalled = expectation(description: "\(mode.rawValue) reset called after cleanup")
      let tlsResetCount = LockedTestCounter()
      let fullResetCount = LockedTestCounter()
      let listener = FakeViewerSecureListener(
        eventsOnStart: [.ready(port: 49_152), .serviceRegistered(exact: true)]
      )
      let identity = try EndpointID(rawValue: "viewer-test")
      let model = ViewerApplicationModel(
        preferences: ViewerPreferences(requiresApproval: { false }, setRequiresApproval: { _ in }),
        dependencies: ViewerRuntimeDependencies(
          loadIdentity: {
            ViewerPreparedIdentity(
              installationID: identity,
              makeListener: { _ in listener }
            )
          },
          resetTLSIdentity: {
            tlsResetCount.increment()
            if mode == .tls { resetCalled.fulfill() }
          },
          resetAllIdentity: {
            fullResetCount.increment()
            if mode == .full { resetCalled.fulfill() }
          },
          generatePairingCode: { try PairingCode("ABCDEF") },
          makeRuntimeComponents: { runtimeLogicalID in
            let owner = FakeAdmissionHandoffOwner(
              runtimeLogicalID: runtimeLogicalID,
              managerGeneration: 1,
              shutdownOperation: { await cleanupGate.wait() }
            )
            let liveWindow = ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
            let compositeJournal = ViewerCompositeSessionJournal(
              runtimeLogicalID: runtimeLogicalID,
              liveWindow: liveWindow
            )
            let explorerInputs = ViewerRuntimeExplorerInputs(
              runtimeLogicalID: runtimeLogicalID,
              liveObservations: liveWindow
            )
            return ViewerRuntimeComponents(
              runtimeLogicalID: runtimeLogicalID,
              managerGeneration: 1,
              handoffOwner: owner,
              sessionControl: owner,
              liveObservations: liveWindow,
              compositeJournal: compositeJournal,
              explorerInputs: explorerInputs,
              cleanupReceipt: ViewerRuntimeCleanupReceipt {
                liveWindow.sealPresentation()
              }
            )
          }
        )
      )
      model.openWindow()
      await waitForStatus(.listening(code: "ABCDEF", paused: false), in: model)
      let explorer = try XCTUnwrap(model.explorerController)
      let composer = try XCTUnwrap(model.composerController)

      switch mode {
      case .tls:
        model.resetTLSIdentity()
      case .full:
        model.requestFullIdentityReset()
        model.confirmFullIdentityReset()
      }
      cleanupGate.waitUntilEntered()
      XCTAssertEqual(tlsResetCount.value + fullResetCount.value, 0)
      XCTAssertEqual(model.status, .stopping)
      cleanupGate.open()
      await fulfillment(of: [resetCalled], timeout: 1)
      XCTAssertEqual(tlsResetCount.value, mode == .tls ? 1 : 0)
      XCTAssertEqual(fullResetCount.value, mode == .full ? 1 : 0)
      XCTAssertEqual(explorer.pendingCleanupWorkCount, 0)
      XCTAssertEqual(composer.pendingCleanupWorkCount, 0)
      _ = await model.prepareForTermination()
    }
  }

  @MainActor
  func testTimelineTailFollowingPreservesManualReadingAndJumpRestoresFollow() async throws {
    var viewport = ViewerTimelineTailViewportState()
    viewport.mount()
    let bottomToken = try XCTUnwrap(
      viewport.observe(
        tailFrame: CGRect(x: 0, y: 619, width: 560, height: 1),
        viewportSize: CGSize(width: 560, height: 620)
      )
    )
    XCTAssertTrue(viewport.shouldFollowNewEvents)
    XCTAssertTrue(viewport.accepts(bottomToken))
    let awayToken = try XCTUnwrap(
      viewport.observe(
        tailFrame: CGRect(x: 0, y: 700, width: 560, height: 1),
        viewportSize: CGSize(width: 560, height: 620)
      )
    )
    XCTAssertFalse(viewport.shouldFollowNewEvents)
    XCTAssertFalse(viewport.accepts(bottomToken))
    XCTAssertTrue(viewport.accepts(awayToken))
    let returnedToken = try XCTUnwrap(
      viewport.observe(
        tailFrame: CGRect(x: 0, y: 619, width: 560, height: 1),
        viewportSize: CGSize(width: 560, height: 620)
      )
    )
    XCTAssertTrue(viewport.shouldFollowNewEvents)
    XCTAssertFalse(viewport.accepts(awayToken))
    viewport.unmount()
    XCTAssertFalse(viewport.shouldFollowNewEvents)
    XCTAssertFalse(viewport.accepts(returnedToken))

    let runtimeLogicalID = UUID()
    let context = try makeObservationContext(
      connectionID: UUID(),
      displayName: "Tail follow"
    )
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      refreshScheduler: ViewerLiveRefreshScheduler(
        now: { 0 },
        scheduleOnMain: { _, action in
          Task { @MainActor in action() }
        }
      )
    )
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: runtimeLogicalID,
        liveObservations: window
      )
    )
    controller.start()
    defer { _ = controller.sealAndClear() }

    func offer(_ sequence: UInt64, content: JSONValue? = nil) throws {
      let observation = try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: content ?? .object(["value": .integer(Int64(sequence))]),
          createdAt: Date(timeIntervalSince1970: Double(sequence)),
          sessionEpoch: SessionEpoch(),
          sequence: sequence
        ),
        viewerWallMilliseconds: Int64(sequence),
        viewerMonotonicNanoseconds: sequence,
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
      XCTAssertEqual(window.offer(observation), .accepted)
      window.waitForProjectionForTesting()
    }

    try offer(1)
    await waitUntilExplorer { controller.timelineRows.count == 1 }
    XCTAssertTrue(controller.autoFollow)

    controller.updateTimelineTailFollowing(false)
    XCTAssertFalse(controller.autoFollow)
    try offer(2)
    await waitUntilExplorer { controller.timelineRows.count == 2 }
    XCTAssertFalse(controller.autoFollow)

    controller.updateTimelineTailFollowing(true)
    XCTAssertTrue(controller.autoFollow)
    controller.updateTimelineTailFollowing(false)
    controller.jumpToLatest()
    XCTAssertTrue(controller.autoFollow)

    controller.selectEvent(try XCTUnwrap(controller.timelineRows.last?.id))
    await waitUntilExplorer { controller.inspectorState == .ready }
    let hostingView = NSHostingView(
      rootView: HStack(spacing: 0) {
        ViewerExplorerTimelineView(explorer: controller)
          .frame(width: 560)
        Divider()
        ViewerExplorerInspectorView(explorer: controller, tab: .constant(.preview))
          .frame(width: 440)
      }
      .environment(\.locale, Locale(identifier: "en"))
      .frame(width: 1_000, height: 620)
    )
    hostingView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 620)
    for _ in 0..<4 {
      await Task.yield()
      hostingView.layoutSubtreeIfNeeded()
    }
    hostingView.displayIfNeeded()

    let preview = try XCTUnwrap(
      descendantViews(of: ViewerReceivedEventTextView.self, in: hostingView).first
    )
    XCTAssertTrue(preview.string.contains("\"value\""))
    if let data = renderedPNGData(of: hostingView), let image = NSImage(data: data) {
      let attachment = XCTAttachment(image: image)
      attachment.name = "NearWire Timeline and Preview refinement"
      attachment.lifetime = .keepAlways
      add(attachment)
    } else {
      XCTFail("The refined Event workspace could not be rendered offscreen.")
    }

    let rowHostingView = NSHostingView(
      rootView: ViewerExplorerTimelineRowView(
        row: ViewerExplorerTimelinePresentationRow(
          id: try XCTUnwrap(controller.timelineRows.last?.id),
          eventType: "test.observation",
          contentSummary: """
            First summary line demonstrates the selected Event content. Second summary line keeps useful context visible. Third summary line remains readable. Fourth-line overflow must be truncated rather than adding another metadata row.
            """,
          viewerWallMilliseconds: 2,
          disposition: ViewerEventDisposition.consumerAccepted.rawValue,
          hasGap: true,
          hasDrop: false,
          hasPresentationConflict: false,
          sessionEnded: false
        )
      )
      .environment(\.locale, Locale(identifier: "en"))
      .frame(width: 520)
      .padding(12)
      .frame(width: 544, height: 110, alignment: .top)
    )
    rowHostingView.frame = NSRect(x: 0, y: 0, width: 544, height: 110)
    rowHostingView.layoutSubtreeIfNeeded()
    rowHostingView.displayIfNeeded()
    if let data = renderedPNGData(of: rowHostingView), let image = NSImage(data: data) {
      let attachment = XCTAttachment(image: image)
      attachment.name = "NearWire Timeline row refinement"
      attachment.lifetime = .keepAlways
      add(attachment)
    } else {
      XCTFail("The refined Timeline row could not be rendered offscreen.")
    }

    let narrowRowHostingView = NSHostingView(
      rootView: ViewerExplorerTimelineRowView(
        row: ViewerExplorerTimelinePresentationRow(
          id: try XCTUnwrap(controller.timelineRows.last?.id),
          eventType: "com.example.feature.with.a.deliberately.long.event.type",
          contentSummary: "A compact three-line summary remains the primary Event content.",
          viewerWallMilliseconds: 2,
          disposition: ViewerEventDisposition.overflowDisplaced.rawValue,
          hasGap: true,
          hasDrop: true,
          hasPresentationConflict: true,
          sessionEnded: true
        )
      )
      .frame(width: 340)
      .fixedSize(horizontal: false, vertical: true)
    )
    narrowRowHostingView.frame = NSRect(x: 0, y: 0, width: 340, height: 160)
    narrowRowHostingView.layoutSubtreeIfNeeded()
    XCTAssertLessThanOrEqual(narrowRowHostingView.fittingSize.height, 100)
    if let data = renderedPNGData(of: narrowRowHostingView), let image = NSImage(data: data) {
      let attachment = XCTAttachment(image: image)
      attachment.name = "NearWire Timeline narrow status refinement"
      attachment.lifetime = .keepAlways
      add(attachment)
    } else {
      XCTFail("The minimum-width Timeline row could not be rendered offscreen.")
    }

    do {
      try offer(
        3,
        content: .object([
          "first": .string(String(repeating: "x", count: 40_000)),
          "second": .string(String(repeating: "y", count: 40_000)),
        ])
      )
    } catch {
      XCTFail("Large preview fixture creation failed: \(error)")
      return
    }
    await waitUntilExplorer { controller.timelineRows.count == 3 }
    controller.selectEvent(try XCTUnwrap(controller.timelineRows.last?.id))
    await waitUntilExplorer { controller.inspectorState == .ready }
    XCTAssertGreaterThan(controller.rendererPreparation?.generic.rawChunkCount ?? 0, 1)
    XCTAssertEqual(controller.previewRawChunk?.index, 0)
    controller.showRawChunk(1)
    XCTAssertEqual(controller.rawChunkIndex, 1)
    XCTAssertEqual(controller.rawChunk?.index, 1)
    XCTAssertEqual(controller.previewRawChunk?.index, 0)
  }

  @MainActor
  func testTimelinePublishesEveryByteValidRowBeyondLegacyCountCap() async throws {
    let runtimeLogicalID = UUID()
    let context = try makeObservationContext(
      connectionID: UUID(),
      displayName: "Count-cap regression"
    )
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      refreshScheduler: ViewerLiveRefreshScheduler(
        now: { 0 },
        scheduleOnMain: { _, action in Task { @MainActor in action() } }
      )
    )
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: runtimeLogicalID,
        liveObservations: window
      )
    )
    controller.start()
    defer { _ = controller.sealAndClear() }

    for sequence in 0..<UInt64(600) {
      let observation = try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: .integer(Int64(sequence)),
          createdAt: Date(timeIntervalSince1970: Double(sequence)),
          sessionEpoch: SessionEpoch(),
          sequence: sequence
        ),
        viewerWallMilliseconds: Int64(sequence),
        viewerMonotonicNanoseconds: sequence,
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
      XCTAssertEqual(window.offer(observation), .accepted)
      if sequence % UInt64(ViewerLiveProjectionLimits.ingressCount) == 63 {
        window.waitForProjectionForTesting()
      }
    }
    window.waitForProjectionForTesting()
    await waitUntilExplorer { controller.timelineRows.count == 600 }

    XCTAssertEqual(window.snapshot().events.count, 600)
    XCTAssertEqual(window.snapshot().gaps.windowOverflowCount, 0)
    guard case .memory(let firstKey)? = controller.timelineRows.first?.id,
      case .memory(let lastKey)? = controller.timelineRows.last?.id
    else { return XCTFail("Expected memory-backed Timeline rows") }
    XCTAssertEqual(firstKey.wireSequence, 0)
    XCTAssertEqual(lastKey.wireSequence, 599)

    controller.updateTimelineTailFollowing(false)
    XCTAssertFalse(controller.autoFollow)
  }

  func testCommittedObservationConsumesPrecomputedCanonicalContent() throws {
    let runtimeLogicalID = UUID()
    let context = try makeObservationContext(
      connectionID: UUID(),
      displayName: "Precomputed Content"
    )
    let precomputed = Data(#"{"precomputed":true}"#.utf8)
    let observation = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: .object(["original": .string("must-not-be-reencoded")]),
        createdAt: Date(timeIntervalSince1970: 1),
        sessionEpoch: SessionEpoch(),
        sequence: 1
      ),
      viewerWallMilliseconds: 1_000,
      viewerMonotonicNanoseconds: 1_000,
      deterministicEventBytes: 128,
      canonicalContent: precomputed,
      initialDisposition: .buffered
    )
    XCTAssertEqual(observation.canonicalProjection.canonicalContent, precomputed)
  }

  func testLiveProjectionEnforcesIngressAndWindowBoundsAndTracksRuntimeState() async throws {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let context = try makeObservationContext(
      connectionID: connectionID,
      displayName: "Bounded projection"
    )
    let epoch = SessionEpoch()
    let projectionQueue = DispatchQueue(label: "ViewerFoundationTests.live-projection-bound")
    let projectionGate = DispatchSemaphore(value: 0)
    projectionQueue.async { projectionGate.wait() }
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      projectionQueue: projectionQueue
    )

    func observation(sequence: UInt64, bytes: Int = 1) throws -> ViewerCommittedEventObservation {
      try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: "Device",
        envelope: makeObservationEnvelope(
          content: .object(["sequence": .integer(Int64(sequence))]),
          createdAt: Date(timeIntervalSince1970: 2_000),
          sessionEpoch: epoch,
          sequence: sequence
        ),
        viewerWallMilliseconds: 2_000_000,
        viewerMonotonicNanoseconds: sequence,
        deterministicEventBytes: bytes,
        initialDisposition: .buffered
      )
    }

    for sequence in 0..<UInt64(ViewerLiveProjectionLimits.ingressCount) {
      XCTAssertEqual(try window.offer(observation(sequence: sequence)), .accepted)
    }
    XCTAssertEqual(
      try window.offer(observation(sequence: UInt64(ViewerLiveProjectionLimits.ingressCount))),
      .untracked
    )
    projectionGate.signal()
    window.waitForProjectionForTesting()

    var snapshot = window.snapshot()
    XCTAssertEqual(snapshot.events.count, ViewerLiveProjectionLimits.ingressCount)
    XCTAssertEqual(snapshot.sessions.count, 1)
    XCTAssertEqual(snapshot.gaps.ingressOverflowCount, 1)
    XCTAssertEqual(
      snapshot.accountedEventBytes,
      ViewerLiveProjectionLimits.ingressCount
        * (ViewerLiveProjectionLimits.fixedEntryOverheadBytes + 1)
    )
    let initialDiagnostics = window.diagnosticsForTesting()
    XCTAssertEqual(initialDiagnostics.ingressOfferCount, 65)
    XCTAssertEqual(initialDiagnostics.drainScheduleCount, 1)
    XCTAssertEqual(initialDiagnostics.dirtySuccessorCount, 1)
    XCTAssertEqual(initialDiagnostics.drainRunCount, 1)
    XCTAssertEqual(initialDiagnostics.maximumConcurrentDrainCount, 1)
    XCTAssertEqual(initialDiagnostics.snapshotPublicationCount, 1)

    for sequence in UInt64(ViewerLiveProjectionLimits.ingressCount + 1)..<600 {
      XCTAssertEqual(try window.offer(observation(sequence: sequence)), .accepted)
      if sequence % 32 == 0 { window.waitForProjectionForTesting() }
    }
    window.waitForProjectionForTesting()
    XCTAssertEqual(try window.offer(observation(sequence: 600)), .accepted)
    window.waitForProjectionForTesting()

    snapshot = window.snapshot()
    XCTAssertEqual(snapshot.events.count, 600)
    XCTAssertEqual(snapshot.gaps.windowOverflowCount, 0)
    XCTAssertTrue(snapshot.events.contains { $0.observation.key.wireSequence == 0 })

    let halfWindowEventBytes =
      ViewerLiveProjectionLimits.retainedBytes / 2
      - ViewerLiveProjectionLimits.fixedEntryOverheadBytes
    for sequence in UInt64(601)...602 {
      XCTAssertEqual(
        try window.offer(observation(sequence: sequence, bytes: halfWindowEventBytes)),
        .accepted
      )
      window.waitForProjectionForTesting()
    }

    snapshot = window.snapshot()
    XCTAssertEqual(snapshot.events.count, 2)
    XCTAssertEqual(snapshot.gaps.windowOverflowCount, 600)
    XCTAssertEqual(window.lostHorizonCount, 601)
    XCTAssertEqual(snapshot.accountedEventBytes, ViewerLiveProjectionLimits.retainedBytes)

    let latest = try XCTUnwrap(
      snapshot.events.first { $0.observation.key.wireSequence == 602 }
    ).observation
    window.laterDisposition(key: latest.key, disposition: .consumerAccepted)
    window.dropsChanged(
      connectionID: connectionID,
      samples: [ViewerDropJournalSample(reason: .localOverflow, count: 7)]
    )
    window.sessionEnded(
      connectionID: connectionID,
      wallMilliseconds: 2_001_000,
      monotonicNanoseconds: 999
    )
    window.waitForProjectionForTesting()

    snapshot = window.snapshot()
    let retained = try XCTUnwrap(
      snapshot.events.first { $0.observation.observationID == latest.observationID }
    )
    XCTAssertEqual(retained.laterDisposition, .consumerAccepted)
    XCTAssertTrue(retained.hasDrop)
    XCTAssertTrue(retained.sessionEnded)
    XCTAssertEqual(snapshot.sessions.first?.positiveDropCount, 7)

    await window.runtimeEnded()
    XCTAssertTrue(window.isCleared)
    XCTAssertTrue(window.snapshot().events.isEmpty)
    XCTAssertTrue(window.snapshot().sessions.isEmpty)
  }

  func testMemorySessionTransferRoundTripsCurrentEventsAndMetadata() async throws {
    let fixture = try makeMemorySessionFixture()
    let directory = try makeTemporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let exportURL = directory.appendingPathComponent("session.json")

    let sourceTransfer = ViewerMemorySessionTransferService(liveWindow: fixture.window)
    let ticket = try await prepareMemorySessionExport(using: sourceTransfer)
    try await executeMemorySessionExport(ticket, using: sourceTransfer, to: exportURL)

    let importedWindow = ViewerLiveEventWindow(runtimeLogicalID: UUID())
    let importedTransfer = ViewerMemorySessionTransferService(liveWindow: importedWindow)
    try await importMemorySession(using: importedTransfer, from: exportURL).get()
    importedWindow.waitForProjectionForTesting()

    let snapshot = importedWindow.snapshot()
    XCTAssertEqual(snapshot.sessions.count, 1)
    XCTAssertEqual(snapshot.sessions.first?.isImported, true)
    XCTAssertEqual(snapshot.events.count, 1)
    let imported = try XCTUnwrap(snapshot.events.first?.observation)
    XCTAssertEqual(imported.envelope.id, fixture.observation.envelope.id)
    XCTAssertEqual(imported.envelope.type, fixture.observation.envelope.type)
    XCTAssertEqual(imported.envelope.content, fixture.observation.envelope.content)
    XCTAssertEqual(
      imported.envelope.causality.correlationID,
      fixture.observation.envelope.causality.correlationID
    )
    XCTAssertEqual(imported.session.applicationIdentifier, "com.nearwire.observation")

    importedWindow.clearCurrentSession()
    XCTAssertTrue(importedWindow.snapshot().events.isEmpty)
    XCTAssertTrue(importedWindow.snapshot().sessions.isEmpty)

    fixture.window.clearCurrentSession()
    XCTAssertTrue(fixture.window.snapshot().events.isEmpty)
    XCTAssertEqual(fixture.window.snapshot().sessions.count, 1)
    XCTAssertEqual(fixture.window.snapshot().sessions.first?.isImported, false)
  }

  func testMemorySessionImportAcceptsMoreThanLegacyCountWithinByteBudget() async throws {
    let fixture = try makeMemorySessionFixture()
    let directory = try makeTemporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let exportURL = directory.appendingPathComponent("source.json")
    let expandedURL = directory.appendingPathComponent("expanded.json")

    let sourceTransfer = ViewerMemorySessionTransferService(liveWindow: fixture.window)
    let ticket = try await prepareMemorySessionExport(using: sourceTransfer)
    try await executeMemorySessionExport(ticket, using: sourceTransfer, to: exportURL)

    var document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: exportURL)) as? [String: Any]
    )
    let originalEvent = try XCTUnwrap((document["events"] as? [[String: Any]])?.first)
    document["events"] = (0..<600).map { sequence in
      var event = originalEvent
      event["wireSequence"] = sequence
      event["viewerMonotonicNanoseconds"] = sequence
      return event
    }
    try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
      .write(to: expandedURL, options: .atomic)

    let importedWindow = ViewerLiveEventWindow(runtimeLogicalID: UUID())
    let importedTransfer = ViewerMemorySessionTransferService(liveWindow: importedWindow)
    try await importMemorySession(using: importedTransfer, from: expandedURL).get()
    importedWindow.waitForProjectionForTesting()

    let snapshot = importedWindow.snapshot()
    XCTAssertEqual(snapshot.events.count, 600)
    XCTAssertEqual(snapshot.events.first?.observation.key.wireSequence, 0)
    XCTAssertEqual(snapshot.events.last?.observation.key.wireSequence, 599)
    XCTAssertLessThan(snapshot.accountedEventBytes, ViewerLiveProjectionLimits.retainedBytes)
  }

  func testMemorySessionImportRejectsInvalidAndOverCapacityFilesWithoutReplacement()
    async throws
  {
    let fixture = try makeMemorySessionFixture()
    let directory = try makeTemporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let validURL = directory.appendingPathComponent("valid.json")
    let invalidURL = directory.appendingPathComponent("invalid.json")
    let capacityURL = directory.appendingPathComponent("capacity.json")
    let transfer = ViewerMemorySessionTransferService(liveWindow: fixture.window)

    let ticket = try await prepareMemorySessionExport(using: transfer)
    try await executeMemorySessionExport(ticket, using: transfer, to: validURL)
    try Data("{}".utf8).write(to: invalidURL, options: .atomic)

    let invalidResult = await importMemorySession(using: transfer, from: invalidURL)
    guard case .failure = invalidResult else {
      return XCTFail("Expected an invalid Session file to be rejected")
    }
    assertMemorySession(fixture.window, stillContains: fixture.observation)

    var document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: validURL)) as? [String: Any]
    )
    let originalDevice = try XCTUnwrap((document["devices"] as? [[String: Any]])?.first)
    document["devices"] = (0...ViewerLiveProjectionLimits.maximumSessions).map { index in
      var device = originalDevice
      device["device"] = "App \(index + 1)"
      device["connection"] = "Connection \(index + 1)"
      return device
    }
    try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
      .write(to: capacityURL, options: .atomic)

    let capacityResult = await importMemorySession(using: transfer, from: capacityURL)
    guard case .failure(.capacityExceeded) = capacityResult else {
      return XCTFail("Expected an over-capacity Session file to be rejected")
    }
    assertMemorySession(fixture.window, stillContains: fixture.observation)
  }

  func testMemorySessionImportCancellationDoesNotReplaceCurrentSession() async throws {
    let fixture = try makeMemorySessionFixture()
    let directory = try makeTemporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let validURL = directory.appendingPathComponent("valid.json")
    let cancellationURL = directory.appendingPathComponent("cancellation.json")
    let transfer = ViewerMemorySessionTransferService(liveWindow: fixture.window)
    let ticket = try await prepareMemorySessionExport(using: transfer)
    try await executeMemorySessionExport(ticket, using: transfer, to: validURL)

    var document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: validURL)) as? [String: Any]
    )
    document["cancellationPadding"] = String(repeating: "x", count: 16 * 1_024 * 1_024)
    try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
      .write(to: cancellationURL, options: .atomic)

    let result: Result<Void, ViewerWorkspaceMutationFailure> = await withCheckedContinuation {
      continuation in
      transfer.importCurrentSession(from: cancellationURL) { result in
        continuation.resume(returning: result)
      }
      transfer.cancelCurrentSessionImport()
    }
    guard case .failure(.cancelled) = result else {
      return XCTFail("Expected the active Session import to report cancellation")
    }
    assertMemorySession(fixture.window, stillContains: fixture.observation)
  }

  @MainActor
  func testPerformanceDashboardControllerPublishesCurrentMemoryProjectionAndRawLocator()
    async throws
  {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let context = try makeObservationContext(
      connectionID: connectionID,
      displayName: "Performance controller"
    )
    let anchor: UInt64 = 10_000_000_000
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      refreshScheduler: ViewerLiveRefreshScheduler(
        now: { anchor },
        scheduleOnMain: { _, action in action() }
      )
    )
    window.sessionStarted(
      try ViewerFrozenSessionMetadata(context: context, nickname: nil),
      connectionID: connectionID
    )
    let content = Data(
      """
      {"schemaVersion":1,"sampledAt":"2026-07-14T01:02:03Z","sampleIntervalMilliseconds":1000,"process":{"cpuPercent":12.5,"memoryFootprintBytes":1024},"display":{"estimatedFramesPerSecond":60,"maximumFramesPerSecond":60},"device":{"batteryLevel":0.5,"batteryState":"unplugged","thermalState":"nominal","lowPowerModeEnabled":false},"transport":{"uplinkBytesPerSecond":20,"downlinkBytesPerSecond":30,"uplinkQueueDepth":1,"downlinkQueueDepth":2,"droppedEventCount":0},"unavailable":[]}
      """.utf8
    )
    let envelope = try makeObservationEnvelope(
      eventType: PerformanceSnapshotSchema.eventType(),
      content: .object(["schemaVersion": .integer(1)]),
      createdAt: Date(timeIntervalSince1970: 1),
      monotonicTimestampNanoseconds: anchor,
      sessionEpoch: SessionEpoch(),
      sequence: 1
    )
    let observation = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: envelope,
      viewerWallMilliseconds: 1_000,
      viewerMonotonicNanoseconds: anchor,
      deterministicEventBytes: content.count,
      canonicalContent: content,
      initialDisposition: .buffered
    )
    XCTAssertEqual(window.offer(observation), .accepted)
    window.waitForProjectionForTesting()

    let controller = ViewerPerformanceDashboardController(
      driver: ViewerPerformanceProjectionDriver(
        live: window,
        currentUptimeNanoseconds: { Int64(anchor) }
      )
    )
    let source = ViewerPerformanceSource.current(
      runtimeLogicalID: runtimeLogicalID,
      connectionID: connectionID
    )
    let target = try ViewerPerformanceDashboardTarget.memoryCurrent(
      source: source,
      deviceStartMonotonicNanoseconds: 0
    )
    _ = controller.replace(target: target, rangeKind: .currentSession)
    controller.requestRefresh()
    await waitUntilPerformanceDashboard {
      if case .ready = controller.model.phase { return true }
      return false
    }

    XCTAssertFalse(controller.model.buckets.isEmpty)
    XCTAssertEqual(
      controller.model.chartProjections.map(\.group),
      ViewerPerformanceChartGroupKind.allCases
    )
    XCTAssertEqual(
      controller.model.chartProjections.first { $0.group == .cpu }?.points(for: .cpuPercent).count,
      1
    )
    let performanceView = NSHostingView(
      rootView: ViewerPerformanceDashboardContent(
        model: controller.model,
        guidance: nil,
        rangeKind: .currentSession
      )
      .environment(\.locale, Locale(identifier: "en"))
      .frame(width: 1_000, height: 800)
    )
    performanceView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
    performanceView.layoutSubtreeIfNeeded()
    performanceView.displayIfNeeded()
    let renderedData = try XCTUnwrap(renderedPNGData(of: performanceView))
    let renderedImage = try XCTUnwrap(NSImage(data: renderedData))
    let attachment = XCTAttachment(image: renderedImage)
    attachment.name = "NearWire populated Performance chart"
    attachment.lifetime = .keepAlways
    add(attachment)
    let bucketIndex = try XCTUnwrap(
      controller.model.buckets.firstIndex {
        $0.numeric.accumulator(for: .cpuPercent).representative != nil
      }
    )
    let request = try XCTUnwrap(
      controller.rawEventRequest(bucketIndex: bucketIndex, metric: .cpuPercent)
    )
    XCTAssertEqual(request.key, observation.key)
    await controller.sealAndWait().value
    XCTAssertTrue(controller.diagnostics.isSealed)
  }

  func testPerformanceFreezeDrainsIngressAndReportsBoundedApplicableLoss() throws {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let context = try makeObservationContext(
      connectionID: connectionID,
      displayName: "Performance freeze"
    )
    let epoch = SessionEpoch()
    let projectionQueue = DispatchQueue(
      label: "ViewerFoundationTests.performance-freeze"
    )
    let projectionGate = DispatchSemaphore(value: 0)
    projectionQueue.async { projectionGate.wait() }
    let anchor: UInt64 = 10_000
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      liveGeneration: 23,
      projectionQueue: projectionQueue,
      refreshScheduler: ViewerLiveRefreshScheduler(
        now: { anchor },
        scheduleOnMain: { _, _ in }
      )
    )

    for sequence in 0..<UInt64(193) {
      let envelope = try makeObservationEnvelope(
        eventType: PerformanceSnapshotSchema.eventType(),
        content: .object(["sequence": .integer(Int64(sequence))]),
        createdAt: Date(timeIntervalSince1970: 12),
        monotonicTimestampNanoseconds: sequence,
        sessionEpoch: epoch,
        sequence: sequence
      )
      let observation = try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: envelope,
        viewerWallMilliseconds: 12_000,
        viewerMonotonicNanoseconds: sequence,
        deterministicEventBytes: 64,
        initialDisposition: .buffered
      )
      let outcome = window.offer(observation)
      XCTAssertEqual(
        outcome,
        sequence < UInt64(ViewerLiveProjectionLimits.ingressCount) ? .accepted : .untracked
      )
    }
    projectionGate.signal()

    let first = try window.freezePerformance(connectionID: connectionID)
    XCTAssertEqual(first.runtimeLogicalID, runtimeLogicalID)
    XCTAssertEqual(first.connectionID, connectionID)
    XCTAssertEqual(first.liveGeneration, 23)
    XCTAssertEqual(first.revision, 1)
    XCTAssertEqual(first.anchorMonotonicNanoseconds, anchor)
    XCTAssertEqual(first.events.count, ViewerLiveProjectionLimits.ingressCount)
    XCTAssertEqual(first.events.map(\.key.wireSequence), Array(0..<UInt64(64)))
    XCTAssertEqual(first.gaps.count, 1)
    XCTAssertEqual(first.gaps.first?.kind, .eventLoss)
    XCTAssertEqual(first.gaps.first?.applicability, .uncertain)
    XCTAssertEqual(first.gaps.first?.count, 129)
    XCTAssertEqual(first.applicableOrUncertainCount, 129)
    XCTAssertTrue(first.hasMoreApplicableGaps)
    XCTAssertLessThanOrEqual(first.accountedBytes, ViewerPerformanceLimits.maximumLiveSliceBytes)
    let firstCarrier = try XCTUnwrap(first.events.first)
    XCTAssertEqual(
      window.performanceEventLocator(for: firstCarrier.key),
      firstCarrier.locator
    )
    XCTAssertNil(
      window.performanceEventLocator(
        for: ViewerEventJournalKey(
          runtimeLogicalID: runtimeLogicalID,
          connectionID: connectionID,
          direction: .viewerToApp,
          wireSequence: firstCarrier.key.wireSequence
        )
      )
    )

    let second = try window.freezePerformance(connectionID: connectionID)
    XCTAssertEqual(second.revision, 2)
    XCTAssertEqual(second.anchorMonotonicNanoseconds, anchor)
    XCTAssertThrowsError(try window.freezePerformance(connectionID: UUID())) { error in
      XCTAssertEqual(error as? ViewerPerformanceFailure, .invalidScope)
    }
    guard case .memory(let observationID) = firstCarrier.locator else {
      return XCTFail("Expected one memory locator")
    }
    XCTAssertEqual(
      observationID,
      window.snapshot().events.first { $0.observation.key == firstCarrier.key }?
        .observation.observationID
    )
    XCTAssertEqual(window.performanceEventLocator(for: firstCarrier.key), firstCarrier.locator)
  }

  func testPerformanceFreezeClassifiesOversizedContentWithoutCopyingIt() throws {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let context = try makeObservationContext(
      connectionID: connectionID,
      displayName: "Oversized performance freeze"
    )
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      refreshScheduler: ViewerLiveRefreshScheduler(
        now: { 1_000 },
        scheduleOnMain: { _, _ in }
      )
    )
    let envelope = try makeObservationEnvelope(
      eventType: PerformanceSnapshotSchema.eventType(),
      content: .null,
      createdAt: Date(timeIntervalSince1970: 1),
      monotonicTimestampNanoseconds: 500,
      sessionEpoch: SessionEpoch(),
      sequence: 1
    )
    let observation = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: envelope,
      viewerWallMilliseconds: 1_000,
      viewerMonotonicNanoseconds: 500,
      deterministicEventBytes: 70_000,
      canonicalContent: Data(repeating: 0x78, count: 70_000),
      initialDisposition: .buffered
    )
    XCTAssertEqual(window.offer(observation), .accepted)

    let slice = try window.freezePerformance(connectionID: connectionID)
    XCTAssertEqual(slice.events.count, 1)
    XCTAssertEqual(slice.copiedContentBytes, 0)
    guard case .oversized(let declaredBytes) = slice.events[0].content else {
      return XCTFail("Expected metadata-only oversized content")
    }
    XCTAssertGreaterThan(declaredBytes, Int64(ViewerPerformanceLimits.maximumRowContentBytes))
  }

  func testHundredThousandLiveOffersUseOneBoundedDrainAndRefreshWake() async throws {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let context = try makeObservationContext(
      connectionID: connectionID,
      displayName: "Hundred thousand offers"
    )
    let epoch = SessionEpoch()
    let projectionQueue = DispatchQueue(
      label: "ViewerFoundationTests.hundred-thousand-live-offers"
    )
    let refreshScheduler = ManualLiveRefreshScheduler()
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      projectionQueue: projectionQueue,
      refreshScheduler: refreshScheduler.value
    )

    func observation(sequence: UInt64) throws -> ViewerCommittedEventObservation {
      try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: .object(["value": .integer(Int64(sequence))]),
          createdAt: Date(timeIntervalSince1970: 2_500),
          sessionEpoch: epoch,
          sequence: sequence
        ),
        viewerWallMilliseconds: 2_500_000,
        viewerMonotonicNanoseconds: sequence,
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
    }

    let maximumMinimumSizedEvents =
      ViewerLiveProjectionLimits.retainedBytes
      / (ViewerLiveProjectionLimits.fixedEntryOverheadBytes + 1)
    for sequence in 0..<UInt64(maximumMinimumSizedEvents) {
      XCTAssertEqual(try window.offer(observation(sequence: sequence)), .accepted)
      window.waitForProjectionForTesting()
    }
    XCTAssertEqual(window.retainedObservationCount, maximumMinimumSizedEvents)
    XCTAssertEqual(refreshScheduler.pendingCount, 1)
    let baseline = window.diagnosticsForTesting()

    let gate = BlockingViewerOperationGate()
    projectionQueue.async { gate.run() }
    XCTAssertEqual(gate.waitUntilEntered(), .success)

    let repeated = try observation(sequence: UInt64(maximumMinimumSizedEvents))
    let baselineFootprint = currentFoundationProcessPhysicalFootprintBytes()
    let callbackStart = DispatchTime.now().uptimeNanoseconds
    var acceptedCount = 0
    var deferredCount = 0
    var untrackedCount = 0
    var unexpectedCount = 0
    for _ in 0..<100_000 {
      switch window.offer(repeated) {
      case .accepted: acceptedCount += 1
      case .deferred: deferredCount += 1
      case .untracked: untrackedCount += 1
      case .identical, .presentationConflict, .sealed: unexpectedCount += 1
      }
    }
    let callbackElapsed = DispatchTime.now().uptimeNanoseconds - callbackStart
    let endingFootprint = currentFoundationProcessPhysicalFootprintBytes()

    XCTAssertEqual(acceptedCount, 1)
    XCTAssertEqual(deferredCount, ViewerLiveProjectionLimits.ingressCount - 1)
    XCTAssertEqual(
      untrackedCount,
      100_000 - ViewerLiveProjectionLimits.ingressCount
    )
    XCTAssertEqual(unexpectedCount, 0)

    gate.release()
    window.waitForProjectionForTesting()
    let diagnostics = window.diagnosticsForTesting()
    XCTAssertEqual(diagnostics.ingressOfferCount - baseline.ingressOfferCount, 100_000)
    XCTAssertEqual(diagnostics.drainScheduleCount - baseline.drainScheduleCount, 1)
    XCTAssertEqual(diagnostics.dirtySuccessorCount - baseline.dirtySuccessorCount, 1)
    XCTAssertEqual(diagnostics.drainRunCount - baseline.drainRunCount, 1)
    XCTAssertEqual(diagnostics.maximumConcurrentDrainCount, 1)
    XCTAssertEqual(
      diagnostics.snapshotPublicationCount - baseline.snapshotPublicationCount,
      1
    )
    XCTAssertEqual(diagnostics.refreshScheduleCount, 1)
    XCTAssertEqual(diagnostics.refreshDeliveryCount, 0)
    XCTAssertEqual(refreshScheduler.pendingCount, 1)

    let snapshot = window.snapshot()
    XCTAssertEqual(snapshot.events.count, maximumMinimumSizedEvents)
    XCTAssertEqual(
      snapshot.gaps.ingressOverflowCount,
      UInt64(100_000 - ViewerLiveProjectionLimits.ingressCount)
    )
    XCTAssertEqual(snapshot.gaps.windowOverflowCount, 1)
    XCTAssertEqual(
      snapshot.accountedEventBytes,
      maximumMinimumSizedEvents
        * (ViewerLiveProjectionLimits.fixedEntryOverheadBytes + 1)
    )

    refreshScheduler.runNext()
    let delivered = window.diagnosticsForTesting()
    XCTAssertEqual(delivered.refreshScheduleCount, 1)
    XCTAssertEqual(delivered.refreshDeliveryCount, 1)

    let footprintGrowth: UInt64? = {
      guard let baselineFootprint, let endingFootprint else { return nil }
      return endingFootprint >= baselineFootprint ? endingFootprint - baselineFootprint : 0
    }()
    let footprintText = footprintGrowth.map(String.init) ?? "unavailable"
    print(
      "NearWire 100,000 live-offer diagnostics: callback-total-ns=\(callbackElapsed), process-footprint-growth=\(footprintText)"
    )

    await window.runtimeEnded()
    XCTAssertTrue(window.isCleared)
    XCTAssertTrue(window.snapshot().events.isEmpty)
  }

  func testPendingMetadataCoversRetainedWindowPlusBlockedIngress() throws {
    let runtimeLogicalID = UUID()
    let context = try makeObservationContext(
      connectionID: UUID(),
      displayName: "Pending metadata capacity"
    )
    let epoch = SessionEpoch()
    let projectionQueue = DispatchQueue(
      label: "ViewerFoundationTests.pending-metadata-capacity"
    )
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      projectionQueue: projectionQueue
    )

    func observation(sequence: UInt64, conflicting: Bool = false) throws
      -> ViewerCommittedEventObservation
    {
      try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: .object([
            "sequence": .integer(Int64(sequence)),
            "conflicting": .bool(conflicting),
          ]),
          createdAt: Date(timeIntervalSince1970: Double(sequence)),
          sessionEpoch: epoch,
          sequence: sequence
        ),
        viewerWallMilliseconds: Int64(sequence),
        viewerMonotonicNanoseconds: sequence,
        deterministicEventBytes: 0,
        initialDisposition: .buffered
      )
    }

    for sequence in 0..<UInt64(ViewerLiveProjectionLimits.maximumByteDerivedEventSlots) {
      XCTAssertEqual(window.offer(try observation(sequence: sequence)), .accepted)
      if sequence % UInt64(ViewerLiveProjectionLimits.ingressCount) == 63 {
        window.waitForProjectionForTesting()
      }
    }
    window.waitForProjectionForTesting()
    XCTAssertEqual(
      window.snapshot().events.count,
      ViewerLiveProjectionLimits.maximumByteDerivedEventSlots
    )

    let gate = BlockingViewerOperationGate()
    projectionQueue.async { gate.run() }
    XCTAssertEqual(gate.waitUntilEntered(), .success)

    for sequence in 0..<UInt64(ViewerLiveProjectionLimits.maximumByteDerivedEventSlots) {
      let original = try observation(sequence: sequence)
      window.laterDisposition(key: original.key, disposition: .consumerAccepted)
      XCTAssertEqual(
        window.offer(try observation(sequence: sequence, conflicting: true)),
        .presentationConflict
      )
    }

    let firstPendingSequence = UInt64(ViewerLiveProjectionLimits.maximumByteDerivedEventSlots)
    let pendingEnd = firstPendingSequence + UInt64(ViewerLiveProjectionLimits.ingressCount)
    for sequence in firstPendingSequence..<pendingEnd {
      let original = try observation(sequence: sequence)
      XCTAssertEqual(window.offer(original), .accepted)
      window.laterDisposition(key: original.key, disposition: .consumerAccepted)
      XCTAssertEqual(
        window.offer(try observation(sequence: sequence, conflicting: true)),
        .presentationConflict
      )
    }

    gate.release()
    window.waitForProjectionForTesting()

    let eventsBySequence = Dictionary(
      uniqueKeysWithValues: window.snapshot().events.map {
        ($0.observation.key.wireSequence, $0)
      }
    )
    for sequence in firstPendingSequence..<pendingEnd {
      let event = try XCTUnwrap(eventsBySequence[sequence])
      XCTAssertEqual(event.laterDisposition, .consumerAccepted)
      XCTAssertTrue(event.hasPresentationConflict)
    }
  }

  func testLiveIngressAdmitsOneMaximumEventAndRejectsTheTwentyMiBOverflow() throws {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let context = try makeObservationContext(connectionID: connectionID, displayName: "Maximum")
    let epoch = SessionEpoch()
    let projectionQueue = DispatchQueue(label: "ViewerFoundationTests.live-projection-byte-bound")
    let projectionGate = DispatchSemaphore(value: 0)
    projectionQueue.async { projectionGate.wait() }
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      projectionQueue: projectionQueue
    )
    let maximum = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: .object(["value": .integer(1)]),
        createdAt: Date(timeIntervalSince1970: 3_000),
        sessionEpoch: epoch,
        sequence: 1
      ),
      viewerWallMilliseconds: 3_000_000,
      viewerMonotonicNanoseconds: 1,
      deterministicEventBytes: 16 * 1_024 * 1_024,
      initialDisposition: .buffered
    )
    let overflow = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: .object(["value": .integer(2)]),
        createdAt: Date(timeIntervalSince1970: 3_000),
        sessionEpoch: epoch,
        sequence: 2
      ),
      viewerWallMilliseconds: 3_000_001,
      viewerMonotonicNanoseconds: 2,
      deterministicEventBytes: 4 * 1_024 * 1_024,
      initialDisposition: .buffered
    )

    XCTAssertEqual(window.offer(maximum), .accepted)
    XCTAssertEqual(window.offer(overflow), .untracked)
    projectionGate.signal()
    window.waitForProjectionForTesting()
    XCTAssertEqual(window.retainedObservationCount, 1)
    XCTAssertEqual(window.snapshot().gaps.ingressOverflowCount, 1)

    let retainedWindow = ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
    let retainedEventBytes =
      16 * 1_024 * 1_024 - ViewerLiveProjectionLimits.fixedEntryOverheadBytes
    let retainedFirst = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: .object(["value": .integer(3)]),
        createdAt: Date(timeIntervalSince1970: 3_000),
        sessionEpoch: epoch,
        sequence: 3
      ),
      viewerWallMilliseconds: 3_000_002,
      viewerMonotonicNanoseconds: 3,
      deterministicEventBytes: retainedEventBytes,
      initialDisposition: .buffered
    )
    let retainedSecond = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: .object(["value": .integer(4)]),
        createdAt: Date(timeIntervalSince1970: 3_000),
        sessionEpoch: epoch,
        sequence: 4
      ),
      viewerWallMilliseconds: 3_000_003,
      viewerMonotonicNanoseconds: 4,
      deterministicEventBytes: retainedEventBytes,
      initialDisposition: .buffered
    )
    let retainedOverflow = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: .object(["value": .integer(5)]),
        createdAt: Date(timeIntervalSince1970: 3_000),
        sessionEpoch: epoch,
        sequence: 5
      ),
      viewerWallMilliseconds: 3_000_004,
      viewerMonotonicNanoseconds: 5,
      deterministicEventBytes: 1,
      initialDisposition: .buffered
    )

    XCTAssertEqual(retainedWindow.offer(retainedFirst), .accepted)
    retainedWindow.waitForProjectionForTesting()
    XCTAssertEqual(retainedWindow.offer(retainedSecond), .accepted)
    retainedWindow.waitForProjectionForTesting()
    XCTAssertEqual(retainedWindow.retainedObservationCount, 2)
    XCTAssertEqual(
      retainedWindow.retainedObservationBytes,
      ViewerLiveProjectionLimits.retainedBytes
    )

    XCTAssertEqual(retainedWindow.offer(retainedOverflow), .accepted)
    retainedWindow.waitForProjectionForTesting()
    let retainedSnapshot = retainedWindow.snapshot()
    XCTAssertEqual(retainedWindow.retainedObservationCount, 2)
    XCTAssertEqual(retainedSnapshot.gaps.windowOverflowCount, 1)
    XCTAssertEqual(
      Set(retainedSnapshot.events.map(\.observation.observationID)),
      Set([retainedSecond.observationID, retainedOverflow.observationID])
    )
  }

  func testLiveSessionMetadataStaysBoundedAndFreshActiveSessionSurvivesChurn() throws {
    let runtimeLogicalID = UUID()
    let blockedQueue = DispatchQueue(label: "ViewerFoundationTests.session-churn-blocked")
    let blockedGate = DispatchSemaphore(value: 0)
    blockedQueue.async { blockedGate.wait() }
    let blockedWindow = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      projectionQueue: blockedQueue
    )

    for index in 0..<1_000 {
      let connectionID = UUID()
      let context = try makeObservationContext(
        connectionID: connectionID,
        displayName: "Blocked churn \(index)"
      )
      blockedWindow.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: connectionID
      )
      blockedWindow.sessionEnded(
        connectionID: connectionID,
        wallMilliseconds: Int64(index + 1),
        monotonicNanoseconds: UInt64(index + 1)
      )
    }
    XCTAssertEqual(blockedWindow.activeSessionMetadataCountForTesting, 0)
    XCTAssertEqual(
      blockedWindow.pendingSessionTerminationCountForTesting,
      ViewerLiveProjectionLimits.maximumSessions
    )
    blockedGate.signal()
    blockedWindow.waitForProjectionForTesting()
    XCTAssertLessThanOrEqual(
      blockedWindow.snapshot().sessions.count,
      ViewerLiveProjectionLimits.maximumSessions
    )
    XCTAssertGreaterThan(blockedWindow.snapshot().gaps.diagnosticLossCount, 0)

    let window = ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
    for index in 0..<ViewerLiveProjectionLimits.maximumSessions {
      let connectionID = UUID()
      let context = try makeObservationContext(
        connectionID: connectionID,
        displayName: "Retained churn \(index)"
      )
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: connectionID
      )
      let observation = try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: .object(["index": .integer(Int64(index))]),
          createdAt: Date(timeIntervalSince1970: Double(index + 1)),
          sessionEpoch: SessionEpoch(),
          sequence: 1
        ),
        viewerWallMilliseconds: Int64(index + 1),
        viewerMonotonicNanoseconds: UInt64(index + 1),
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
      XCTAssertEqual(window.offer(observation), .accepted)
      window.waitForProjectionForTesting()
      window.sessionEnded(
        connectionID: connectionID,
        wallMilliseconds: Int64(index + 100),
        monotonicNanoseconds: UInt64(index + 100)
      )
      window.waitForProjectionForTesting()
    }
    XCTAssertEqual(window.snapshot().sessions.count, ViewerLiveProjectionLimits.maximumSessions)

    let freshConnectionID = UUID()
    let freshContext = try makeObservationContext(
      connectionID: freshConnectionID,
      displayName: "Fresh active session"
    )
    window.sessionStarted(
      try ViewerFrozenSessionMetadata(context: freshContext, nickname: nil),
      connectionID: freshConnectionID
    )
    let freshObservation = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: freshContext,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: .object(["fresh": .bool(true)]),
        createdAt: Date(timeIntervalSince1970: 100),
        sessionEpoch: SessionEpoch(),
        sequence: 1
      ),
      viewerWallMilliseconds: 100,
      viewerMonotonicNanoseconds: 100,
      deterministicEventBytes: 1,
      initialDisposition: .buffered
    )
    XCTAssertEqual(window.offer(freshObservation), .accepted)
    window.waitForProjectionForTesting()
    let snapshot = window.snapshot()
    XCTAssertEqual(snapshot.sessions.count, ViewerLiveProjectionLimits.maximumSessions)
    XCTAssertTrue(snapshot.sessions.contains { $0.connectionID == freshConnectionID })
    XCTAssertTrue(
      snapshot.events.contains { $0.observation.key.connectionID == freshConnectionID }
    )
    XCTAssertEqual(snapshot.gaps.windowOverflowCount, 1)
  }

  func testBlockedProjectionRetainsTerminalTransitionsBeforeReplacementSessions() throws {
    let runtimeLogicalID = UUID()
    let projectionQueue = DispatchQueue(
      label: "ViewerFoundationTests.session-generation-transition"
    )
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      projectionQueue: projectionQueue
    )

    func observation(
      context: ViewerAdmissionSessionContext,
      index: Int,
      generation: String
    ) throws -> ViewerCommittedEventObservation {
      try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: .object([
            "generation": .string(generation),
            "index": .integer(Int64(index)),
          ]),
          createdAt: Date(timeIntervalSince1970: Double(index + 1)),
          sessionEpoch: SessionEpoch(),
          sequence: 1
        ),
        viewerWallMilliseconds: Int64(index + 1),
        viewerMonotonicNanoseconds: UInt64(index + 1),
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
    }

    var initialContexts: [ViewerAdmissionSessionContext] = []
    for index in 0..<ViewerLiveProjectionLimits.maximumSessions {
      let context = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Initial generation \(index)"
      )
      initialContexts.append(context)
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: context.connectionID
      )
      XCTAssertEqual(
        window.offer(try observation(context: context, index: index, generation: "initial")),
        .accepted
      )
    }
    window.waitForProjectionForTesting()
    XCTAssertEqual(window.snapshot().sessions.count, ViewerLiveProjectionLimits.maximumSessions)

    let projectionBlocked = DispatchSemaphore(value: 0)
    let projectionRelease = DispatchSemaphore(value: 0)
    projectionQueue.async {
      projectionBlocked.signal()
      projectionRelease.wait()
    }
    XCTAssertEqual(projectionBlocked.wait(timeout: .now() + 1), .success)

    for (index, context) in initialContexts.enumerated() {
      window.sessionEnded(
        connectionID: context.connectionID,
        wallMilliseconds: Int64(index + 100),
        monotonicNanoseconds: UInt64(index + 100)
      )
    }

    var replacementConnectionIDs = Set<UUID>()
    for index in 0..<ViewerLiveProjectionLimits.maximumSessions {
      let context = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Replacement generation \(index)"
      )
      replacementConnectionIDs.insert(context.connectionID)
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: context.connectionID
      )
      XCTAssertEqual(
        window.offer(try observation(context: context, index: index, generation: "replacement")),
        .accepted
      )
    }
    XCTAssertEqual(
      window.activeSessionMetadataCountForTesting,
      ViewerLiveProjectionLimits.maximumSessions
    )
    XCTAssertEqual(
      window.pendingSessionTerminationCountForTesting,
      ViewerLiveProjectionLimits.maximumSessions
    )

    projectionRelease.signal()
    window.waitForProjectionForTesting()
    let snapshot = window.snapshot()
    XCTAssertEqual(snapshot.sessions.count, ViewerLiveProjectionLimits.maximumSessions)
    XCTAssertEqual(Set(snapshot.sessions.map(\.connectionID)), replacementConnectionIDs)
    XCTAssertEqual(snapshot.events.count, ViewerLiveProjectionLimits.maximumSessions)
    XCTAssertEqual(
      Set(snapshot.events.map(\.observation.key.connectionID)),
      replacementConnectionIDs
    )
    XCTAssertEqual(
      snapshot.gaps.windowOverflowCount,
      UInt64(ViewerLiveProjectionLimits.maximumSessions)
    )
  }

  func testBlockedProjectionReconcilesEndedReplacementBeforeFreshGeneration() throws {
    let runtimeLogicalID = UUID()
    let projectionQueue = DispatchQueue(
      label: "ViewerFoundationTests.three-session-generations"
    )
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      projectionQueue: projectionQueue
    )

    func makeEvent(
      _ context: ViewerAdmissionSessionContext,
      generation: String,
      index: Int
    ) throws -> ViewerCommittedEventObservation {
      try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: .object(["generation": .string(generation)]),
          createdAt: Date(timeIntervalSince1970: Double(index + 1)),
          sessionEpoch: SessionEpoch(),
          sequence: 1
        ),
        viewerWallMilliseconds: Int64(index + 1),
        viewerMonotonicNanoseconds: UInt64(index + 1),
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
    }

    var initialContexts: [ViewerAdmissionSessionContext] = []
    for index in 0..<ViewerLiveProjectionLimits.maximumSessions {
      let context = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Initial three-generation \(index)"
      )
      initialContexts.append(context)
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: context.connectionID
      )
      XCTAssertEqual(window.offer(try makeEvent(context, generation: "A", index: index)), .accepted)
    }
    window.waitForProjectionForTesting()

    let blocked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    projectionQueue.async {
      blocked.signal()
      release.wait()
    }
    XCTAssertEqual(blocked.wait(timeout: .now() + 1), .success)

    for (index, context) in initialContexts.enumerated() {
      window.sessionEnded(
        connectionID: context.connectionID,
        wallMilliseconds: Int64(index + 100),
        monotonicNanoseconds: UInt64(index + 100)
      )
    }
    for index in 0..<ViewerLiveProjectionLimits.maximumSessions {
      let context = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Ended replacement \(index)"
      )
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: context.connectionID
      )
      XCTAssertEqual(window.offer(try makeEvent(context, generation: "B", index: index)), .accepted)
      window.sessionEnded(
        connectionID: context.connectionID,
        wallMilliseconds: Int64(index + 200),
        monotonicNanoseconds: UInt64(index + 200)
      )
    }

    var freshConnectionIDs = Set<UUID>()
    for index in 0..<ViewerLiveProjectionLimits.maximumSessions {
      let context = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Fresh generation \(index)"
      )
      freshConnectionIDs.insert(context.connectionID)
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: context.connectionID
      )
      XCTAssertEqual(window.offer(try makeEvent(context, generation: "C", index: index)), .accepted)
    }
    XCTAssertEqual(
      window.activeSessionMetadataCountForTesting,
      ViewerLiveProjectionLimits.maximumSessions
    )
    XCTAssertEqual(
      window.pendingSessionTerminationCountForTesting,
      ViewerLiveProjectionLimits.maximumSessions
    )

    release.signal()
    window.waitForProjectionForTesting()
    let snapshot = window.snapshot()
    XCTAssertEqual(Set(snapshot.sessions.map(\.connectionID)), freshConnectionIDs)
    XCTAssertEqual(Set(snapshot.events.map(\.observation.key.connectionID)), freshConnectionIDs)
    XCTAssertTrue(snapshot.sessions.allSatisfy { $0.endedMonotonicNanoseconds == nil })
    XCTAssertEqual(
      snapshot.gaps.windowOverflowCount,
      UInt64(ViewerLiveProjectionLimits.maximumSessions * 2)
    )
    XCTAssertGreaterThanOrEqual(
      snapshot.gaps.diagnosticLossCount,
      UInt64(ViewerLiveProjectionLimits.maximumSessions)
    )
  }

  func testBlockedSingleSlotChurnPreservesLatestActiveGeneration() throws {
    let runtimeLogicalID = UUID()
    let projectionQueue = DispatchQueue(label: "ViewerFoundationTests.single-slot-churn")
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      projectionQueue: projectionQueue
    )

    func makeEvent(
      _ context: ViewerAdmissionSessionContext,
      generation: Int
    ) throws -> ViewerCommittedEventObservation {
      try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: .object(["generation": .integer(Int64(generation))]),
          createdAt: Date(timeIntervalSince1970: Double(generation + 1)),
          sessionEpoch: SessionEpoch(),
          sequence: 1
        ),
        viewerWallMilliseconds: Int64(generation + 1),
        viewerMonotonicNanoseconds: UInt64(generation + 1),
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
    }

    var initialContexts: [ViewerAdmissionSessionContext] = []
    for index in 0..<ViewerLiveProjectionLimits.maximumSessions {
      let context = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Single-slot initial \(index)"
      )
      initialContexts.append(context)
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: context.connectionID
      )
      XCTAssertEqual(window.offer(try makeEvent(context, generation: index)), .accepted)
    }
    window.waitForProjectionForTesting()

    let blocked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    projectionQueue.async {
      blocked.signal()
      release.wait()
    }
    XCTAssertEqual(blocked.wait(timeout: .now() + 1), .success)

    let displaced = initialContexts[0]
    window.sessionEnded(
      connectionID: displaced.connectionID,
      wallMilliseconds: 100,
      monotonicNanoseconds: 100
    )
    let intermediateCount = ViewerLiveProjectionLimits.maximumSessions + 4
    for generation in 0..<intermediateCount {
      let context = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Single-slot intermediate \(generation)"
      )
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: context.connectionID
      )
      XCTAssertEqual(window.offer(try makeEvent(context, generation: 100 + generation)), .accepted)
      window.sessionEnded(
        connectionID: context.connectionID,
        wallMilliseconds: Int64(200 + generation),
        monotonicNanoseconds: UInt64(200 + generation)
      )
    }

    let latest = try makeObservationContext(
      connectionID: UUID(),
      displayName: "Single-slot latest"
    )
    window.sessionStarted(
      try ViewerFrozenSessionMetadata(context: latest, nickname: nil),
      connectionID: latest.connectionID
    )
    XCTAssertEqual(window.offer(try makeEvent(latest, generation: 1_000)), .accepted)

    release.signal()
    window.waitForProjectionForTesting()
    let snapshot = window.snapshot()
    let expectedSessionIDs = Set(initialContexts.dropFirst().map(\.connectionID)).union([
      latest.connectionID
    ])
    XCTAssertEqual(Set(snapshot.sessions.map(\.connectionID)), expectedSessionIDs)
    XCTAssertEqual(Set(snapshot.events.map(\.observation.key.connectionID)), expectedSessionIDs)
    XCTAssertTrue(
      snapshot.sessions.contains { session in
        session.connectionID == latest.connectionID
          && session.metadata.displayName == "Single-slot latest"
          && session.endedMonotonicNanoseconds == nil
      })
    XCTAssertEqual(
      snapshot.gaps.windowOverflowCount,
      UInt64(intermediateCount + 1)
    )
  }

  func testDirectObservationModeSurvivesDispositionAndReconcilesAtLifecycleTransition() throws {
    let runtimeLogicalID = UUID()
    let window = ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)

    func makeEvent(
      _ context: ViewerAdmissionSessionContext,
      index: Int
    ) throws -> ViewerCommittedEventObservation {
      try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: .object(["index": .integer(Int64(index))]),
          createdAt: Date(timeIntervalSince1970: Double(index + 1)),
          sessionEpoch: SessionEpoch(),
          sequence: 1
        ),
        viewerWallMilliseconds: Int64(index + 1),
        viewerMonotonicNanoseconds: UInt64(index + 1),
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
    }

    var directObservations: [ViewerCommittedEventObservation] = []
    for index in 0..<ViewerLiveProjectionLimits.maximumSessions {
      let context = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Direct observation \(index)"
      )
      let observation = try makeEvent(context, index: index)
      directObservations.append(observation)
      XCTAssertEqual(window.offer(observation), .accepted)
      window.waitForProjectionForTesting()
      if index == 0 {
        window.laterDisposition(key: observation.key, disposition: .transportAdmitted)
        window.waitForProjectionForTesting()
      }
    }
    XCTAssertEqual(window.snapshot().sessions.count, ViewerLiveProjectionLimits.maximumSessions)
    XCTAssertEqual(window.snapshot().events.count, ViewerLiveProjectionLimits.maximumSessions)
    XCTAssertEqual(window.snapshot().events.first?.laterDisposition, .transportAdmitted)

    let managedContext = try makeObservationContext(
      connectionID: UUID(),
      displayName: "Managed lifecycle"
    )
    window.sessionStarted(
      try ViewerFrozenSessionMetadata(context: managedContext, nickname: nil),
      connectionID: managedContext.connectionID
    )
    let managedObservation = try makeEvent(managedContext, index: 1_000)
    XCTAssertEqual(window.offer(managedObservation), .accepted)
    window.waitForProjectionForTesting()

    let snapshot = window.snapshot()
    XCTAssertEqual(snapshot.sessions.map(\.connectionID), [managedContext.connectionID])
    XCTAssertEqual(
      snapshot.events.map(\.observation.observationID),
      [managedObservation.observationID]
    )
    XCTAssertEqual(
      snapshot.gaps.windowOverflowCount,
      UInt64(ViewerLiveProjectionLimits.maximumSessions)
    )
    XCTAssertTrue(
      directObservations.allSatisfy { direct in
        !snapshot.events.contains { $0.observation.observationID == direct.observationID }
      }
    )
  }

  func testShortLifecycleManagedSessionRetainsEventBeforeFirstAndEstablishedDrain() throws {
    func exercise(establishedLifecycle: Bool) throws {
      let runtimeLogicalID = UUID()
      let projectionQueue = DispatchQueue(
        label: "ViewerFoundationTests.short-session.\(establishedLifecycle)"
      )
      let window = ViewerLiveEventWindow(
        runtimeLogicalID: runtimeLogicalID,
        projectionQueue: projectionQueue
      )
      if establishedLifecycle {
        let establishedContext = try makeObservationContext(
          connectionID: UUID(),
          displayName: "Established lifecycle"
        )
        window.sessionStarted(
          try ViewerFrozenSessionMetadata(context: establishedContext, nickname: nil),
          connectionID: establishedContext.connectionID
        )
        window.waitForProjectionForTesting()
      }

      let projectionEntered = DispatchSemaphore(value: 0)
      let projectionRelease = DispatchSemaphore(value: 0)
      projectionQueue.async {
        projectionEntered.signal()
        projectionRelease.wait()
      }
      XCTAssertEqual(projectionEntered.wait(timeout: .now() + 1), .success)

      let context = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Short lifecycle"
      )
      let observation = try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: .object(["value": .string("short")]),
          createdAt: Date(timeIntervalSince1970: 2),
          sessionEpoch: SessionEpoch(),
          sequence: 1
        ),
        viewerWallMilliseconds: 2,
        viewerMonotonicNanoseconds: 2,
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: context.connectionID
      )
      XCTAssertEqual(window.offer(observation), .accepted)
      window.laterDisposition(key: observation.key, disposition: .transportAdmitted)
      window.sessionEnded(
        connectionID: context.connectionID,
        wallMilliseconds: 3,
        monotonicNanoseconds: 3
      )
      projectionRelease.signal()
      window.waitForProjectionForTesting()

      let snapshot = window.snapshot()
      let retained = try XCTUnwrap(
        snapshot.events.first { $0.observation.observationID == observation.observationID }
      )
      XCTAssertEqual(retained.laterDisposition, .transportAdmitted)
      XCTAssertTrue(retained.sessionEnded)
      XCTAssertTrue(
        snapshot.sessions.contains {
          $0.connectionID == context.connectionID && $0.endedMonotonicNanoseconds == 3
        }
      )
      XCTAssertEqual(snapshot.gaps.windowOverflowCount, 0)
      XCTAssertEqual(snapshot.gaps.diagnosticLossCount, 0)
    }

    try exercise(establishedLifecycle: false)
    try exercise(establishedLifecycle: true)
  }

  func testDuplicateSessionChurnReleasesOwnerlessAuthorityAcrossCapacityHorizon() throws {
    let runtimeLogicalID = UUID()
    let projectionQueue = DispatchQueue(label: "ViewerFoundationTests.authority-churn")
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      projectionQueue: projectionQueue
    )

    func makeEvent(
      context: ViewerAdmissionSessionContext,
      generation: Int
    ) throws -> ViewerCommittedEventObservation {
      try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: .object(["generation": .integer(Int64(generation))]),
          createdAt: Date(timeIntervalSince1970: Double(generation + 1)),
          sessionEpoch: SessionEpoch(),
          sequence: 1
        ),
        viewerWallMilliseconds: Int64(generation + 1),
        viewerMonotonicNanoseconds: UInt64(generation + 1),
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
    }

    for index in 0..<(ViewerLiveProjectionLimits.maximumSessions - 1) {
      let context = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Authority anchor \(index)"
      )
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: context.connectionID
      )
    }
    var currentContext = try makeObservationContext(
      connectionID: UUID(),
      displayName: "Authority generation 0"
    )
    window.sessionStarted(
      try ViewerFrozenSessionMetadata(context: currentContext, nickname: nil),
      connectionID: currentContext.connectionID
    )
    var currentEvent = try makeEvent(context: currentContext, generation: 0)
    XCTAssertEqual(window.offer(currentEvent), .accepted)
    window.waitForProjectionForTesting()

    let churnCount =
      ViewerLiveProjectionLimits.maximumByteDerivedEventSlots
      + ViewerLiveProjectionLimits.ingressCount + 24
    for generation in 1...churnCount {
      let projectionEntered = DispatchSemaphore(value: 0)
      let projectionRelease = DispatchSemaphore(value: 0)
      projectionQueue.async {
        projectionEntered.signal()
        projectionRelease.wait()
      }
      XCTAssertEqual(projectionEntered.wait(timeout: .now() + 1), .success)
      let duplicate = try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: currentContext,
        nickname: nil,
        envelope: currentEvent.envelope,
        viewerWallMilliseconds: Int64(generation + 10_000),
        viewerMonotonicNanoseconds: UInt64(generation + 10_000),
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
      XCTAssertEqual(window.offer(duplicate), .deferred)
      window.sessionEnded(
        connectionID: currentContext.connectionID,
        wallMilliseconds: Int64(generation + 20_000),
        monotonicNanoseconds: UInt64(generation + 20_000)
      )

      let nextContext = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Authority generation \(generation)"
      )
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: nextContext, nickname: nil),
        connectionID: nextContext.connectionID
      )
      let nextEvent = try makeEvent(context: nextContext, generation: generation)
      XCTAssertEqual(window.offer(nextEvent), .accepted)
      projectionRelease.signal()
      window.waitForProjectionForTesting()
      XCTAssertEqual(window.ownerlessAuthorityCountForTesting, 0)
      XCTAssertEqual(window.authorityCountForTesting, window.retainedObservationCount)
      currentContext = nextContext
      currentEvent = nextEvent
    }

    XCTAssertEqual(window.retainedObservationCount, 1)
    XCTAssertEqual(window.authorityCountForTesting, 1)
    XCTAssertEqual(window.ownerlessAuthorityCountForTesting, 0)
    XCTAssertEqual(
      window.snapshot().events.first?.observation.observationID,
      currentEvent.observationID
    )
    XCTAssertEqual(window.snapshot().gaps.windowOverflowCount, UInt64(churnCount * 2))
  }

  @MainActor
  func testLiveRefreshIsLatestOnlyTenHertzAndPausedPresentationSchedulesNothing() throws {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let context = try makeObservationContext(connectionID: connectionID, displayName: "Refresh")
    let epoch = SessionEpoch()
    let scheduler = ManualLiveRefreshScheduler()
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      refreshScheduler: scheduler.value
    )
    let generations = LockedUInt64Collection()
    window.setRefreshHandler { generations.append($0) }

    func offer(_ sequence: UInt64) throws {
      let value = try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: .object(["value": .integer(Int64(sequence))]),
          createdAt: Date(timeIntervalSince1970: 4_000),
          sessionEpoch: epoch,
          sequence: sequence
        ),
        viewerWallMilliseconds: 4_000_000,
        viewerMonotonicNanoseconds: sequence,
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
      XCTAssertEqual(window.offer(value), .accepted)
      window.waitForProjectionForTesting()
    }

    try offer(1)
    try offer(2)
    XCTAssertEqual(scheduler.pendingCount, 1)
    scheduler.runNext()
    XCTAssertEqual(generations.values.count, 1)
    XCTAssertEqual(generations.values.last, window.snapshot().generation)

    try offer(3)
    XCTAssertEqual(scheduler.pendingCount, 1)
    XCTAssertEqual(
      scheduler.nextDelay,
      ViewerLiveProjectionLimits.refreshIntervalNanoseconds
    )
    window.setPresentationPaused(true)
    scheduler.runNext()
    XCTAssertEqual(generations.values.count, 1)
    try offer(4)
    XCTAssertEqual(scheduler.pendingCount, 0)

    window.setPresentationPaused(false)
    XCTAssertEqual(scheduler.pendingCount, 1)
    scheduler.runNext()
    XCTAssertEqual(generations.values.count, 2)
    XCTAssertEqual(generations.values.last, window.snapshot().generation)
    XCTAssertEqual(Array(Mirror(reflecting: window.snapshot()).children).count, 2)
    XCTAssertEqual(Array(Mirror(reflecting: window.snapshot().events[0]).children).count, 0)
    XCTAssertEqual(Array(Mirror(reflecting: window.snapshot().sessions[0]).children).count, 0)
    XCTAssertEqual(Array(Mirror(reflecting: window.snapshot().gaps).children).count, 0)
  }

  func testLiveEvaluatorMatchesMetadataJSONAndPresenceFilters() throws {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let context = try makeObservationContext(connectionID: connectionID, displayName: "Evaluator")
    let epoch = SessionEpoch()
    let first = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: "Primary",
      envelope: makeObservationEnvelope(
        content: .object([
          "items": .array([.object(["value": .integer(42)])]),
          "message": .string("alpha value"),
          "nullable": .null,
          "ratio": .number(1.5),
          "enabled": .bool(true),
        ]),
        createdAt: Date(timeIntervalSince1970: 5_000),
        sessionEpoch: epoch,
        sequence: 1
      ),
      viewerWallMilliseconds: 5_000_000,
      viewerMonotonicNanoseconds: 10,
      deterministicEventBytes: 100,
      initialDisposition: .buffered
    )
    let second = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: "Primary",
      envelope: makeObservationEnvelope(
        content: .object([
          "items": .array([.object(["value": .integer(7)])]),
          "message": .string("beta value"),
          "nullable": .string("present"),
        ]),
        createdAt: Date(timeIntervalSince1970: 5_001),
        sessionEpoch: epoch,
        sequence: 2
      ),
      viewerWallMilliseconds: 5_001_000,
      viewerMonotonicNanoseconds: 20,
      deterministicEventBytes: 100,
      initialDisposition: .buffered
    )
    let snapshot = ViewerLiveProjectionSnapshot(
      runtimeLogicalID: runtimeLogicalID,
      generation: 9,
      events: [
        ViewerLiveEventSnapshot(
          observation: first,
          laterDisposition: .expired,
          hasPresentationConflict: true,
          hasGap: true,
          hasDrop: true,
          sessionEnded: false
        ),
        ViewerLiveEventSnapshot(
          observation: second,
          laterDisposition: nil,
          hasPresentationConflict: false,
          hasGap: false,
          hasDrop: false,
          sessionEnded: false
        ),
      ],
      sessions: [
        ViewerLiveSessionSnapshot(
          connectionID: connectionID,
          metadata: first.session,
          isImported: false,
          positiveDropCount: 1,
          endedWallMilliseconds: nil,
          endedMonotonicNanoseconds: nil
        )
      ],
      gaps: ViewerLiveGapSnapshot(
        ingressOverflowCount: 0,
        windowOverflowCount: 0,
        residentConflictCount: 1,
        diagnosticLossCount: 0,
      ),
      accountedEventBytes: 2 * (ViewerLiveProjectionLimits.fixedEntryOverheadBytes + 100)
    )
    let request = try ViewerLiveEvaluationRequest(
      runtimeLogicalID: runtimeLogicalID,
      deviceScope: ViewerLiveDeviceScope(selectedConnectionIDs: [connectionID]),
      predicates: [
        .eventTypeEqualsAny(["test.other", "test.observation"]),
        .eventTypePrefix("test."),
        .contentContains("alpha"),
        .applicationIdentifiers(["com.nearwire.observation"]),
        .applicationVersions(["1.0"]),
        .directions(["appToViewer"]),
        .priorities(["normal", "high"]),
        .wallTime(from: 5_000_000, through: 5_000_000),
        .jsonExists(path: "$.items[0].value"),
        .jsonAny(path: "$.items[0].value", equalsAny: [.integer(7), .integer(42)]),
        .jsonStringContains(path: "$.message", value: "alpha"),
        .json(path: "$.nullable", equals: .null),
        .json(path: "$.ratio", equals: .real(1.5)),
        .json(path: "$.enabled", equals: .boolean(true)),
        .hasGap,
        .hasDrop,
        .hasTerminalDisposition,
      ]
    )
    let evaluator = ViewerLiveEventEvaluator(nowNanoseconds: { 0 })

    guard case .complete(let output) = evaluator.evaluate(snapshot: snapshot, request: request)
    else { return XCTFail("Expected a complete bounded live evaluation") }
    XCTAssertEqual(output.snapshotGeneration, 9)
    XCTAssertEqual(output.matchedKeys, [first.key])
    XCTAssertNil(output.transientExclusion)
    XCTAssertGreaterThan(output.predicateCheckCount, 0)
    XCTAssertGreaterThan(output.jsonNodeVisitCount, 0)

    for (from, through, expected) in [
      (5_000_000, 5_000_000, [first.key]),
      (5_000_001, 5_000_999, []),
      (5_001_000, 5_001_000, [second.key]),
    ] {
      let boundaryRequest = try ViewerLiveEvaluationRequest(
        runtimeLogicalID: runtimeLogicalID,
        predicates: [.wallTime(from: Int64(from), through: Int64(through))]
      )
      guard
        case .complete(let boundaryOutput) = evaluator.evaluate(
          snapshot: snapshot,
          request: boundaryRequest
        )
      else { return XCTFail("Expected exact receive-time boundary evaluation") }
      XCTAssertEqual(boundaryOutput.matchedKeys, expected)
    }

    let wrongDeviceRequest = try ViewerLiveEvaluationRequest(
      runtimeLogicalID: runtimeLogicalID,
      deviceScope: ViewerLiveDeviceScope(selectedConnectionIDs: [UUID()]),
      predicates: []
    )
    guard
      case .complete(let wrongDeviceOutput) = evaluator.evaluate(
        snapshot: snapshot,
        request: wrongDeviceRequest
      )
    else { return XCTFail("Expected an exact-device non-match") }
    XCTAssertTrue(wrongDeviceOutput.matchedKeys.isEmpty)

    XCTAssertEqual(Array(Mirror(reflecting: request).children).count, 0)
    XCTAssertEqual(Array(Mirror(reflecting: request.deviceScope).children).count, 0)
    XCTAssertEqual(Array(Mirror(reflecting: evaluator).children).count, 0)
    XCTAssertEqual(Array(Mirror(reflecting: output).children).count, 1)
  }

  func testLiveEvaluatorReturnsNoPartialCompletionOnCancellationDeadlineOrShapeOverflow()
    throws
  {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let context = try makeObservationContext(connectionID: connectionID, displayName: "Budget")
    let observation = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: .object(["value": .integer(1)]),
        createdAt: Date(timeIntervalSince1970: 6_000),
        sessionEpoch: SessionEpoch(),
        sequence: 1
      ),
      viewerWallMilliseconds: 6_000_000,
      viewerMonotonicNanoseconds: 1,
      deterministicEventBytes: 1,
      initialDisposition: .buffered
    )
    let event = ViewerLiveEventSnapshot(
      observation: observation,
      laterDisposition: nil,
      hasPresentationConflict: false,
      hasGap: false,
      hasDrop: false,
      sessionEnded: false
    )
    let snapshot = ViewerLiveProjectionSnapshot(
      runtimeLogicalID: runtimeLogicalID,
      generation: 1,
      events: [event],
      sessions: [],
      gaps: ViewerLiveGapSnapshot(
        ingressOverflowCount: 0,
        windowOverflowCount: 0,
        residentConflictCount: 0,
        diagnosticLossCount: 0,
      ),
      accountedEventBytes: ViewerLiveProjectionLimits.fixedEntryOverheadBytes + 1
    )
    let request = try ViewerLiveEvaluationRequest(
      runtimeLogicalID: runtimeLogicalID,
      predicates: [.jsonExists(path: "$.value")]
    )

    XCTAssertEqual(
      ViewerLiveEventEvaluator(nowNanoseconds: { 0 }).evaluate(
        snapshot: snapshot,
        request: request,
        isCancelled: { true }
      ),
      .cancelled
    )
    let deadlineClock = SteppingNanosecondClock(
      values: [0, ViewerLiveEventEvaluator.deadlineNanoseconds]
    )
    XCTAssertEqual(
      ViewerLiveEventEvaluator(nowNanoseconds: { deadlineClock.now() }).evaluate(
        snapshot: snapshot,
        request: request
      ),
      .refineRequired
    )
    let oversized = ViewerLiveProjectionSnapshot(
      runtimeLogicalID: runtimeLogicalID,
      generation: 2,
      events: Array(
        repeating: event,
        count: ViewerLiveProjectionLimits.maximumByteDerivedEventSlots + 1
      ),
      sessions: [],
      gaps: snapshot.gaps,
      accountedEventBytes: snapshot.accountedEventBytes
    )
    XCTAssertEqual(
      ViewerLiveEventEvaluator(nowNanoseconds: { 0 }).evaluate(
        snapshot: oversized,
        request: request
      ),
      .refineRequired
    )

    var nested: JSONValue = .integer(1)
    for _ in 0..<16 { nested = .object(["a": nested]) }
    let deepObservation = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: nested,
        createdAt: Date(timeIntervalSince1970: 6_001),
        sessionEpoch: SessionEpoch(),
        sequence: 2
      ),
      viewerWallMilliseconds: 6_001_000,
      viewerMonotonicNanoseconds: 2,
      deterministicEventBytes: 1,
      initialDisposition: .buffered
    )
    let deepEvent = ViewerLiveEventSnapshot(
      observation: deepObservation,
      laterDisposition: nil,
      hasPresentationConflict: false,
      hasGap: false,
      hasDrop: false,
      sessionEnded: false
    )
    let maximumPredicateEventCount =
      ViewerLiveEventEvaluator.maximumPredicateChecks / 32
    let maximumSnapshot = ViewerLiveProjectionSnapshot(
      runtimeLogicalID: runtimeLogicalID,
      generation: 3,
      events: Array(repeating: deepEvent, count: maximumPredicateEventCount),
      sessions: [],
      gaps: snapshot.gaps,
      accountedEventBytes: maximumPredicateEventCount
        * (ViewerLiveProjectionLimits.fixedEntryOverheadBytes + 1)
    )
    let maximumPath = "$" + Array(repeating: ".a", count: 16).joined()
    let maximumRequest = try ViewerLiveEvaluationRequest(
      runtimeLogicalID: runtimeLogicalID,
      predicates: Array(repeating: .jsonExists(path: maximumPath), count: 32)
    )
    guard
      case .complete(let maximumOutput) = ViewerLiveEventEvaluator(
        nowNanoseconds: { 0 }
      ).evaluate(snapshot: maximumSnapshot, request: maximumRequest)
    else { return XCTFail("Expected the exact maximum predicate shape to complete") }
    XCTAssertEqual(maximumOutput.matchedKeys.count, maximumPredicateEventCount)
    XCTAssertEqual(maximumOutput.predicateCheckCount, 16_384)
    XCTAssertEqual(maximumOutput.jsonNodeVisitCount, 512 * 32 * 16)
    XCTAssertLessThanOrEqual(
      maximumOutput.jsonNodeVisitCount,
      ViewerLiveEventEvaluator.maximumJSONNodeVisits
    )
    XCTAssertEqual(
      ViewerLiveEvaluationResult.refineGuidance,
      "Refine the live filter to evaluate within bounded work."
    )

    XCTAssertThrowsError(
      try ViewerLiveDeviceScope(selectedConnectionIDs: [connectionID, connectionID])
    )
    XCTAssertThrowsError(
      try ViewerLiveEvaluationRequest(
        runtimeLogicalID: runtimeLogicalID,
        predicates: Array(repeating: .hasGap, count: 33)
      )
    )
    XCTAssertThrowsError(
      try ViewerLiveEvaluationRequest(
        runtimeLogicalID: runtimeLogicalID,
        predicates: [.jsonExists(path: "$[999999999999999999999999999]")]
      )
    )
  }

  @MainActor
  func testRendererRegistryPreparesBoundedRawPrettyLogTableAndNumericFallbacks() throws {
    var genericObject: [String: Any] = [:]
    for index in 0..<129 { genericObject[String(format: "key-%03d", index)] = index }
    genericObject["payload"] = String(repeating: "é", count: 33_000)
    let genericData = try JSONSerialization.data(
      withJSONObject: genericObject,
      options: [.sortedKeys]
    )
    let genericDetail = makeRendererBuffer(
      rowID: 1,
      eventType: "custom.generic",
      content: genericData
    )
    let model = ViewerEventInspectorModel(runtimeLogicalID: UUID())
    let genericRequest = model.select(
      preparedLiveBuffer: genericDetail,
      identity: .memory(rendererJournalKey(1))
    )
    XCTAssertEqual(genericRequest.rendererKind, .genericJSON)
    let genericResult = ViewerRendererPreparer().prepare(genericRequest)
    XCTAssertTrue(model.apply(genericResult))
    XCTAssertEqual(genericResult.preparation.presentedKind, .genericJSON)
    XCTAssertEqual(genericResult.preparation.generic.prettyState, .prepared)
    XCTAssertLessThanOrEqual(
      genericResult.preparation.generic.prettyText?.utf8.count ?? .max,
      ViewerJSONInspectionLimits.maximumPrettyOutputBytes
    )
    XCTAssertGreaterThan(genericResult.preparation.generic.rawChunkCount, 1)
    var reconstructed = Data()
    for index in 0..<genericResult.preparation.generic.rawChunkCount {
      let chunk = try model.rawChunk(at: index)
      XCTAssertLessThanOrEqual(chunk.byteRange.count, ViewerJSONInspectionLimits.rawChunkBytes)
      reconstructed.append(Data(chunk.text.utf8))
      XCTAssertLessThanOrEqual(
        chunk.focusedAccessibilityText.utf8.count,
        ViewerJSONInspectionLimits.maximumFocusedAccessibilityBytes
      )
    }
    XCTAssertEqual(reconstructed, genericData)

    let unsafeMessage = "line\n\u{202E}unsafe " + String(repeating: "x", count: 70_000)
    let logData = try JSONSerialization.data(
      withJSONObject: ["message": unsafeMessage],
      options: [.sortedKeys]
    )
    let logRequest = model.select(
      preparedLiveBuffer: makeRendererBuffer(rowID: 2, eventType: "log.network", content: logData),
      identity: .memory(rendererJournalKey(2))
    )
    XCTAssertEqual(logRequest.rendererKind, .log)
    let logResult = ViewerRendererPreparer().prepare(logRequest)
    guard case .log(let log)? = logResult.preparation.specialized else {
      return XCTFail("Expected bounded log preparation")
    }
    let logText = log.chunks.joined()
    XCTAssertEqual(logResult.preparation.presentedKind, .log)
    XCTAssertTrue(logText.contains("<U+000A>"))
    XCTAssertTrue(logText.contains("<U+202E>"))
    XCTAssertTrue(logText.hasPrefix("⟦"))
    XCTAssertTrue(logText.hasSuffix("…⟧"))
    XCTAssertTrue(log.chunks.allSatisfy { $0.utf8.count <= ViewerLogPreparation.chunkBytes })
    XCTAssertLessThanOrEqual(log.derivedTextBytes, ViewerLogPreparation.maximumOutputBytes)
    XCTAssertLessThanOrEqual(
      log.focusedAccessibilityText.utf8.count,
      ViewerJSONInspectionLimits.maximumFocusedAccessibilityBytes
    )

    var tableObject: [String: Any] = [
      "boolean": true,
      "control": "line\n\u{202E}value",
      "null": NSNull(),
      "real": 1.5,
      "string": "value",
    ]
    for index in 0..<129 { tableObject[String(format: "field-%03d", index)] = index }
    let tableData = try JSONSerialization.data(
      withJSONObject: tableObject,
      options: [.sortedKeys]
    )
    let tableRequest = model.select(
      preparedLiveBuffer: makeRendererBuffer(
        rowID: 3, eventType: "table.metrics", content: tableData),
      identity: .memory(rendererJournalKey(3))
    )
    let tableResult = ViewerRendererPreparer().prepare(tableRequest)
    guard case .table(let table)? = tableResult.preparation.specialized else {
      return XCTFail("Expected bounded table preparation")
    }
    XCTAssertEqual(table.rows.count, ViewerTablePreparation.maximumRetainedRows)
    XCTAssertEqual(try table.page(offset: 0).count, ViewerTablePreparation.pageRows)
    XCTAssertEqual(try table.page(offset: 64).count, ViewerTablePreparation.pageRows)
    XCTAssertTrue(table.hasMore)
    XCTAssertEqual(table.scannedEntryCount, 134)
    XCTAssertLessThanOrEqual(
      table.derivedTextBytes,
      ViewerTablePreparation.maximumDerivedTextBytes
    )
    XCTAssertTrue(
      table.rows.allSatisfy {
        $0.keyPreview.utf8.count <= ViewerTablePreparation.maximumKeyPreviewBytes
          && $0.valuePreview.utf8.count <= ViewerTablePreparation.maximumValuePreviewBytes
          && $0.focusedAccessibilityText.utf8.count
            <= ViewerJSONInspectionLimits.maximumFocusedAccessibilityBytes
      }
    )
    XCTAssertTrue(table.rows.map(\.valuePreview).joined().contains("<U+202E>"))

    let numericObject = Dictionary(uniqueKeysWithValues: (0..<8).map { ("v\($0)", $0) })
    let numericData = try JSONSerialization.data(
      withJSONObject: Array(repeating: numericObject, count: 201),
      options: [.sortedKeys]
    )
    let numericRequest = model.select(
      preparedLiveBuffer: makeRendererBuffer(
        rowID: 4, eventType: "chart.metrics", content: numericData),
      identity: .memory(rendererJournalKey(4))
    )
    let numericResult = ViewerRendererPreparer().prepare(numericRequest)
    guard case .numeric(let numeric)? = numericResult.preparation.specialized else {
      return XCTFail("Expected bounded numeric preparation")
    }
    XCTAssertLessThanOrEqual(numeric.fields.count, ViewerNumericPreparation.maximumFields)
    XCTAssertEqual(numeric.points.count, ViewerNumericPreparation.maximumPoints)
    XCTAssertEqual(numeric.scannedRowCount, ViewerNumericPreparation.maximumRows)
    XCTAssertTrue(numeric.hasMore)
    XCTAssertTrue(numeric.points.allSatisfy { $0.value.isFinite })

    let timelineRequest = model.select(
      preparedLiveBuffer: makeRendererBuffer(
        rowID: 7,
        eventType: "timeline.state",
        content: Data("{\"state\":true}".utf8)
      ),
      identity: .memory(rendererJournalKey(7))
    )
    let timelineResult = ViewerRendererPreparer().prepare(timelineRequest)
    guard case .timeline(let timeline)? = timelineResult.preparation.specialized else {
      return XCTFail("Expected metadata-only timeline preparation")
    }
    XCTAssertEqual(timeline.eventType, "timeline.state")
    XCTAssertEqual(timeline.direction, "appToViewer")
    XCTAssertEqual(timeline.disposition, "buffered")

    let incompatibleData = try JSONSerialization.data(withJSONObject: ["value": 1])
    let incompatibleRequest = model.select(
      preparedLiveBuffer: makeRendererBuffer(
        rowID: 5,
        eventType: "log.incompatible",
        content: incompatibleData
      ),
      identity: .memory(rendererJournalKey(5))
    )
    let incompatibleResult = ViewerRendererPreparer().prepare(incompatibleRequest)
    XCTAssertEqual(incompatibleResult.preparation.presentedKind, .genericJSON)
    XCTAssertEqual(incompatibleResult.preparation.fallbackReason, .incompatibleShape)
    XCTAssertEqual(
      incompatibleResult.preparation.fallbackGuidance,
      ViewerRendererFallbackReason.guidance
    )

    let cancelledResult = ViewerRendererPreparer().prepare(logRequest, isCancelled: { true })
    XCTAssertEqual(cancelledResult.preparation.presentedKind, .genericJSON)
    XCTAssertEqual(cancelledResult.preparation.fallbackReason, .cancelled)
    let cancelledTableResult = ViewerRendererPreparer().prepare(
      tableRequest,
      isCancelled: { true }
    )
    XCTAssertEqual(cancelledTableResult.preparation.presentedKind, .genericJSON)
    XCTAssertEqual(cancelledTableResult.preparation.fallbackReason, .cancelled)
    let deadlineClock = SteppingNanosecondClock(
      values: [0, 100_000_000, 200_000_000, 300_000_000, 400_000_000, 500_000_000]
    )
    let deadlineResult = ViewerRendererPreparer(
      nowNanoseconds: { deadlineClock.now() }
    ).prepare(logRequest)
    XCTAssertEqual(deadlineResult.preparation.presentedKind, .genericJSON)
    XCTAssertEqual(deadlineResult.preparation.fallbackReason, .refineRequired)
    let tableDeadlineClock = SteppingNanosecondClock(
      values: [
        0, ViewerJSONInspectionLimits.deadlineNanoseconds,
        0, ViewerJSONInspectionLimits.deadlineNanoseconds,
        0, ViewerJSONInspectionLimits.deadlineNanoseconds,
      ]
    )
    let tableDeadlineResult = ViewerRendererPreparer(
      nowNanoseconds: { tableDeadlineClock.now() }
    ).prepare(tableRequest)
    XCTAssertEqual(tableDeadlineResult.preparation.presentedKind, .genericJSON)
    XCTAssertEqual(tableDeadlineResult.preparation.fallbackReason, .refineRequired)

    let oversizedLogData = try JSONSerialization.data(
      withJSONObject: String(repeating: "x", count: ViewerLogPreparation.maximumInputBytes + 1),
      options: [.fragmentsAllowed]
    )
    let oversizedLogRequest = model.select(
      preparedLiveBuffer: makeRendererBuffer(
        rowID: 6,
        eventType: "log.oversized",
        content: oversizedLogData
      ),
      identity: .memory(rendererJournalKey(6))
    )
    let oversizedLogResult = ViewerRendererPreparer().prepare(oversizedLogRequest)
    XCTAssertEqual(oversizedLogResult.preparation.presentedKind, .genericJSON)
    XCTAssertEqual(oversizedLogResult.preparation.fallbackReason, .inputTooLarge)
    XCTAssertEqual(oversizedLogResult.preparation.generic.prettyState, .chunkedRawOnly)
    let diagnostics = [
      String(describing: genericRequest),
      String(reflecting: logResult.preparation),
      String(describing: log),
      String(reflecting: table),
      String(describing: numeric),
      String(reflecting: model),
    ].joined()
    XCTAssertFalse(diagnostics.contains("unsafe"))
    XCTAssertFalse(diagnostics.contains("payload"))
    XCTAssertTrue(Mirror(reflecting: model).children.isEmpty)
  }

  @MainActor
  func testRendererExtremeValidatedShapesRemainBounded() throws {
    let model = ViewerEventInspectorModel(runtimeLogicalID: UUID())
    let preparer = ViewerRendererPreparer(nowNanoseconds: { 0 })

    let depth = 128
    let depthData = Data(
      (String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth))
        .utf8
    )
    let depthRequest = model.select(
      preparedLiveBuffer: makeRendererBuffer(
        rowID: 20, eventType: "custom.depth", content: depthData),
      identity: .memory(rendererJournalKey(20))
    )
    let depthResult = preparer.prepare(depthRequest)
    XCTAssertEqual(depthResult.preparation.presentedKind, .genericJSON)
    XCTAssertEqual(depthResult.preparation.generic.prettyState, .prepared)
    XCTAssertNotNil(depthResult.preparation.generic.prettyText)

    let repeatedEntry = Array("\"a\":0".utf8)
    var hundredThousandEntries = Data()
    hundredThousandEntries.reserveCapacity(600_001)
    hundredThousandEntries.append(0x7B)
    for index in 0..<100_000 {
      if index > 0 { hundredThousandEntries.append(0x2C) }
      hundredThousandEntries.append(contentsOf: repeatedEntry)
    }
    hundredThousandEntries.append(0x7D)
    let entryRequest = model.select(
      preparedLiveBuffer: makeRendererBuffer(
        rowID: 21,
        eventType: "table.maximum-entries",
        content: hundredThousandEntries
      ),
      identity: .memory(rendererJournalKey(21))
    )
    let entryResult = preparer.prepare(entryRequest)
    guard case .table(let entryTable)? = entryResult.preparation.specialized else {
      return XCTFail("Expected bounded table preparation for the 100,000-entry fixture")
    }
    XCTAssertEqual(entryTable.rows.count, ViewerTablePreparation.maximumRetainedRows)
    XCTAssertEqual(entryTable.scannedEntryCount, 4_096)
    XCTAssertTrue(entryTable.hasMore)
    XCTAssertLessThanOrEqual(
      entryTable.derivedTextBytes,
      ViewerTablePreparation.maximumDerivedTextBytes
    )

    let oneMiB = 1 * 1_024 * 1_024
    var maximumKeyData = Data("{\"".utf8)
    maximumKeyData.append(Data(repeating: 0x61, count: oneMiB))
    maximumKeyData.append(Data("\":0}".utf8))
    let keyRequest = model.select(
      preparedLiveBuffer: makeRendererBuffer(
        rowID: 22,
        eventType: "table.maximum-key",
        content: maximumKeyData
      ),
      identity: .memory(rendererJournalKey(22))
    )
    let keyResult = preparer.prepare(keyRequest)
    XCTAssertEqual(keyResult.preparation.presentedKind, .genericJSON)
    XCTAssertEqual(keyResult.preparation.fallbackReason, .inputTooLarge)
    XCTAssertEqual(keyResult.preparation.generic.prettyState, .chunkedRawOnly)
    XCTAssertGreaterThan(keyResult.preparation.generic.rawChunkCount, 1)

    var maximumMessageData = Data("{\"message\":\"".utf8)
    maximumMessageData.append(Data(repeating: 0x78, count: oneMiB))
    maximumMessageData.append(Data("\"}".utf8))
    let messageRequest = model.select(
      preparedLiveBuffer: makeRendererBuffer(
        rowID: 23,
        eventType: "log.maximum-message",
        content: maximumMessageData
      ),
      identity: .memory(rendererJournalKey(23))
    )
    let messageResult = preparer.prepare(messageRequest)
    XCTAssertEqual(messageResult.preparation.presentedKind, .genericJSON)
    XCTAssertEqual(messageResult.preparation.fallbackReason, .inputTooLarge)
    XCTAssertEqual(messageResult.preparation.generic.prettyState, .chunkedRawOnly)

    let maximumEventBytes = ViewerJSONInspectionLimits.maximumCanonicalBytes
    var maximumEventData = Data([0x22])
    maximumEventData.reserveCapacity(maximumEventBytes)
    maximumEventData.append(Data(repeating: 0x78, count: maximumEventBytes - 2))
    maximumEventData.append(0x22)
    let maximumRequest = model.select(
      preparedLiveBuffer: makeRendererBuffer(
        rowID: 24,
        eventType: "custom.maximum-event",
        content: maximumEventData
      ),
      identity: .memory(rendererJournalKey(24))
    )
    let maximumResult = preparer.prepare(maximumRequest)
    XCTAssertTrue(model.apply(maximumResult))
    XCTAssertEqual(model.canonicalBuffer?.contentByteCount, maximumEventBytes)
    XCTAssertEqual(maximumResult.preparation.presentedKind, .genericJSON)
    XCTAssertEqual(maximumResult.preparation.generic.prettyState, .chunkedRawOnly)
    XCTAssertEqual(maximumResult.preparation.generic.rawChunkCount, 256)
    XCTAssertEqual(try model.rawChunk(at: 0).byteRange.count, 64 * 1_024)
    XCTAssertEqual(try model.rawChunk(at: 255).byteRange.count, 64 * 1_024)
    XCTAssertLessThanOrEqual(
      try model.rawChunk(at: 255).focusedAccessibilityText.utf8.count,
      ViewerJSONInspectionLimits.maximumFocusedAccessibilityBytes
    )

    let diagnostics = [
      String(reflecting: depthResult.preparation),
      String(reflecting: entryTable),
      String(reflecting: keyResult.preparation),
      String(reflecting: messageResult.preparation),
      String(reflecting: maximumResult.preparation),
    ].joined()
    XCTAssertFalse(diagnostics.contains(String(repeating: "x", count: 32)))
    XCTAssertTrue(Mirror(reflecting: maximumResult.preparation).children.isEmpty)
  }

  @MainActor
  func testInspectorPreparationCancelsReplacedGenerationAndClearsCanonicalBuffer() async throws {
    let runtimeLogicalID = UUID()
    let model = ViewerEventInspectorModel(runtimeLogicalID: runtimeLogicalID)
    let queue = DispatchQueue(label: "com.nearwire.viewer.tests.renderer-replacement")
    let gate = DispatchSemaphore(value: 0)
    queue.async { gate.wait() }
    let service = ViewerRendererPreparationService(queue: queue)
    let results = LockedRendererResultCollection()
    let completed = expectation(description: "All rapid renderer generations completed")
    completed.expectedFulfillmentCount = 64
    var requests: [(request: ViewerRendererPreparationRequest, data: Data)] = []
    for index in 0..<64 {
      let data = try JSONSerialization.data(
        withJSONObject: ["message": "selection-\(index)-secret"]
      )
      let rowID = Int64(index + 10)
      let request = model.select(
        preparedLiveBuffer: makeRendererBuffer(
          rowID: rowID,
          eventType: "log.selection",
          content: data
        ),
        identity: .memory(rendererJournalKey(rowID))
      )
      requests.append((request, data))
      service.submit(request) { result in
        results.append(result)
        completed.fulfill()
      }
    }
    XCTAssertEqual(results.values.count, 63)
    XCTAssertEqual(service.pendingWorkCount, 1)
    XCTAssertEqual(service.retainedRequestLimit, 2)
    XCTAssertEqual(service.retainedRequestCountForTesting, 1)
    gate.signal()
    await fulfillment(of: [completed], timeout: 2)

    XCTAssertEqual(results.values.count, 64)
    for prior in requests.dropLast() {
      let result = try XCTUnwrap(results.values.first { $0.token == prior.request.token })
      XCTAssertEqual(result.preparation.fallbackReason, .cancelled)
      XCTAssertFalse(model.apply(result))
    }
    let latest = try XCTUnwrap(requests.last)
    let latestResult = try XCTUnwrap(
      results.values.first { $0.token == latest.request.token }
    )
    XCTAssertTrue(model.apply(latestResult))
    XCTAssertEqual(model.canonicalBuffer?.content, latest.data)
    XCTAssertEqual(model.selectedIdentity, latest.request.token.eventIdentity)
    XCTAssertEqual(model.preparation?.presentedKind, .log)
    XCTAssertLessThanOrEqual(
      model.preparation?.generic.rawChunkCount ?? .max,
      1
    )
    model.clear()
    XCTAssertNil(model.canonicalBuffer)
    XCTAssertNil(model.preparation)
    XCTAssertNil(model.selectedIdentity)
    XCTAssertFalse(model.apply(latestResult))
  }

  @MainActor func testBlockedRendererAndComposerCleanupJoinsAndReleasesAllContent() async throws {
    let rendererQueue = DispatchQueue(label: "ViewerFoundationTests.blocked-renderer-cleanup")
    let rendererEntered = DispatchSemaphore(value: 0)
    let rendererGate = DispatchSemaphore(value: 0)
    rendererQueue.async {
      rendererEntered.signal()
      rendererGate.wait()
    }
    XCTAssertEqual(rendererEntered.wait(timeout: .now() + 1), .success)

    let inspector = ViewerEventInspectorModel(runtimeLogicalID: UUID())
    let rendererRequest = inspector.select(
      preparedLiveBuffer: makeRendererBuffer(
        rowID: 700,
        eventType: "log.cleanup",
        content: Data(#"{"message":"blocked-renderer-secret"}"#.utf8)
      ),
      identity: .memory(rendererJournalKey(700))
    )
    let rendererService = ViewerRendererPreparationService(queue: rendererQueue)
    let rendererResults = LockedRendererResultCollection()
    let rendererFinished = expectation(description: "Cancelled renderer completed")
    rendererService.submit(rendererRequest) { result in
      rendererResults.append(result)
      rendererFinished.fulfill()
    }
    XCTAssertEqual(rendererService.pendingWorkCount, 1)
    let rendererCleanup = rendererService.cancelAndWait()

    let composerQueue = DispatchQueue(label: "ViewerFoundationTests.blocked-composer-cleanup")
    let composerEntered = DispatchSemaphore(value: 0)
    let composerGate = DispatchSemaphore(value: 0)
    composerQueue.async {
      composerEntered.signal()
      composerGate.wait()
    }
    XCTAssertEqual(composerEntered.wait(timeout: .now() + 1), .success)

    let composer = try ViewerControlComposerModel(
      runtimeLogicalID: UUID(),
      activeLimits: .default
    )
    XCTAssertEqual(
      composer.replaceCharacters(
        field: .eventType,
        range: NSRange(location: 0, length: 0),
        replacement: "control.cleanup"
      ),
      .applied
    )
    XCTAssertEqual(
      composer.replaceCharacters(
        field: .content,
        range: NSRange(location: 0, length: 0),
        replacement: #"{"message":"blocked-composer-secret"}"#
      ),
      .applied
    )
    XCTAssertEqual(
      composer.replaceCharacters(
        field: .ttl,
        range: NSRange(location: 0, length: 0),
        replacement: "60000"
      ),
      .applied
    )
    let composerRequest = composer.makePreparationRequest()
    let composerService = ViewerComposerPreparationService(queue: composerQueue)
    let composerResults = LockedComposerResultCollection()
    let composerFinished = expectation(description: "Cancelled composer completed")
    composerService.submit(composerRequest) { result in
      composerResults.append(result)
      composerFinished.fulfill()
    }
    XCTAssertEqual(composerService.pendingWorkCount, 1)
    let composerCleanup = composerService.cancelAndWait()

    rendererGate.signal()
    composerGate.signal()
    async let rendererJoined: Void = rendererCleanup.value
    async let composerJoined: Void = composerCleanup.value
    _ = await (rendererJoined, composerJoined)
    await fulfillment(of: [rendererFinished, composerFinished], timeout: 1)

    XCTAssertEqual(rendererService.pendingWorkCount, 0)
    XCTAssertEqual(composerService.pendingWorkCount, 0)
    let rendererResult = try XCTUnwrap(rendererResults.values.first)
    XCTAssertEqual(rendererResult.preparation.fallbackReason, .cancelled)
    guard
      case .failure(let composerFailure, let diagnostics) =
        try XCTUnwrap(composerResults.values.first).outcome
    else { return XCTFail("Expected cancelled composer preparation") }
    XCTAssertEqual(composerFailure, .cancelled)
    XCTAssertEqual(diagnostics, ViewerComposerPreparationDiagnostics())

    inspector.clear()
    composer.clear()
    XCTAssertNil(inspector.canonicalBuffer)
    XCTAssertNil(inspector.preparation)
    XCTAssertThrowsError(try inspector.rawChunk(at: 0))
    XCTAssertEqual(composer.eventType.value, "")
    XCTAssertEqual(composer.content.value, "")
    XCTAssertEqual(composer.ttl.value, "")
    XCTAssertNil(composer.preparedEvent)
    XCTAssertFalse(inspector.apply(rendererResult))
    XCTAssertFalse(composer.apply(try XCTUnwrap(composerResults.values.first)))
    let diagnosticsText = [
      String(reflecting: rendererResult),
      String(reflecting: composerResults.values.first as Any),
      String(reflecting: ViewerAsyncWorkTracker()),
    ].joined()
    XCTAssertFalse(diagnosticsText.contains("blocked-renderer-secret"))
    XCTAssertFalse(diagnosticsText.contains("blocked-composer-secret"))
  }

  func testIncrementalTextBuffersEnforceEveryOperatorCapWithoutFullValueRescans() throws {
    var multibyte = ViewerIncrementalTextBuffer(
      maximumUTF8Bytes: 8,
      maximumUnicodeScalars: 4
    )
    XCTAssertEqual(
      multibyte.replaceCharacters(in: NSRange(location: 0, length: 0), with: "é🙂"),
      .applied
    )
    XCTAssertEqual(multibyte.utf8ByteCount, 6)
    XCTAssertEqual(multibyte.unicodeScalarCount, 2)
    XCTAssertEqual(multibyte.utf16Count, 3)
    XCTAssertEqual(
      multibyte.replaceCharacters(in: NSRange(location: 1, length: 2), with: "ab"),
      .applied
    )
    XCTAssertEqual(multibyte.value, "éab")
    XCTAssertEqual(multibyte.utf8ByteCount, 4)
    XCTAssertEqual(multibyte.unicodeScalarCount, 3)
    XCTAssertEqual(
      multibyte.replaceCharacters(in: NSRange(location: 3, length: 0), with: "🙂"),
      .applied
    )
    XCTAssertEqual(multibyte.utf8ByteCount, 8)
    XCTAssertEqual(multibyte.unicodeScalarCount, 4)
    let acceptedValue = multibyte.value
    XCTAssertEqual(
      multibyte.replaceCharacters(in: NSRange(location: 5, length: 0), with: "x"),
      .rejected(.byteLimit)
    )
    XCTAssertEqual(multibyte.value, acceptedValue)
    XCTAssertEqual(multibyte.diagnostics.appliedEditCount, 3)
    XCTAssertEqual(multibyte.diagnostics.rejectedEditCount, 1)
    XCTAssertEqual(multibyte.diagnostics.storageCopyCount, 3)
    XCTAssertEqual(multibyte.diagnostics.fullValueRescanCount, 0)

    var rapid = ViewerIncrementalTextBuffer(maximumUTF8Bytes: 1)
    for index in 0..<10_000 {
      let range = NSRange(location: 0, length: rapid.utf16Count)
      XCTAssertEqual(
        rapid.replaceCharacters(in: range, with: index.isMultiple(of: 2) ? "a" : "b"),
        .applied
      )
    }
    XCTAssertEqual(rapid.utf8ByteCount, 1)
    XCTAssertEqual(rapid.diagnostics.appliedEditCount, 10_000)
    XCTAssertEqual(rapid.diagnostics.storageCopyCount, 10_000)
    XCTAssertEqual(rapid.diagnostics.fullValueRescanCount, 0)

    let expandedLimits = try EventValidationLimits(
      maximumEncodedContentBytes: 4_194_304,
      maximumEncodedModelBytes: 16_842_752,
      maximumTTLMilliseconds: 604_800_000
    )
    let composerLimits = try ViewerComposerTextLimits(activeLimits: expandedLimits)
    XCTAssertEqual(composerLimits.eventTypeBytes, 128)
    XCTAssertEqual(composerLimits.contentBytes, 4_177_920)
    XCTAssertEqual(composerLimits.ttlBytes, 9)
    let contentLimited = try ViewerComposerTextLimits(
      activeLimits: EventValidationLimits(
        maximumEncodedContentBytes: 1_048_576,
        maximumEncodedModelBytes: 134_217_728
      )
    )
    XCTAssertEqual(contentLimited.contentBytes, 1_048_576)
    let hardCapped = try ViewerComposerTextLimits(
      activeLimits: EventValidationLimits(
        maximumEncodedContentBytes: 16_777_216,
        maximumEncodedModelBytes: 134_217_728
      )
    )
    XCTAssertEqual(
      hardCapped.contentBytes,
      (ViewerComposerTextLimits.hardModelBytes - ViewerComposerTextLimits.modelReserveBytes) / 4
    )

    var ttl = ViewerIncrementalTextBuffer(
      maximumUTF8Bytes: 9,
      characterPolicy: .asciiDigits
    )
    XCTAssertEqual(
      ttl.replaceCharacters(in: NSRange(location: 0, length: 0), with: "604800000"),
      .applied
    )
    XCTAssertEqual(
      try ViewerTTLTextParser.parse(
        ttl.value,
        maximumMilliseconds: expandedLimits.maximumTTLMilliseconds
      ),
      604_800_000
    )
    XCTAssertEqual(
      ttl.replaceCharacters(in: NSRange(location: 9, length: 0), with: "+"),
      .rejected(.unsupportedCharacter)
    )
    XCTAssertThrowsError(
      try ViewerTTLTextParser.parse(" 1", maximumMilliseconds: 604_800_000)
    ) { error in
      XCTAssertEqual(error as? ViewerTTLValidationError, .invalidSyntax)
    }
    for invalidSyntax in ["", "+1", "-1", "1 ", "18446744073709551616"] {
      XCTAssertThrowsError(
        try ViewerTTLTextParser.parse(
          invalidSyntax,
          maximumMilliseconds: 604_800_000
        )
      ) { error in
        XCTAssertEqual(error as? ViewerTTLValidationError, .invalidSyntax)
      }
    }
    XCTAssertThrowsError(
      try ViewerTTLTextParser.parse("0", maximumMilliseconds: 604_800_000)
    ) { error in
      XCTAssertEqual(error as? ViewerTTLValidationError, .outOfRange)
    }
    XCTAssertEqual(
      try ViewerTTLTextParser.parse("1", maximumMilliseconds: 604_800_000),
      1
    )
    XCTAssertThrowsError(
      try ViewerTTLTextParser.parse("1234567890", maximumMilliseconds: 604_800_000)
    ) { error in
      XCTAssertEqual(error as? ViewerTTLValidationError, .invalidSyntax)
    }
    XCTAssertThrowsError(
      try ViewerTTLTextParser.parse("604800001", maximumMilliseconds: 604_800_000)
    ) { error in
      XCTAssertEqual(error as? ViewerTTLValidationError, .outOfRange)
    }

    var operators = ViewerExplorerOperatorTextBuffers()
    XCTAssertEqual(
      operators.replaceCharacters(
        field: .search,
        range: NSRange(location: 0, length: 0),
        replacement: String(repeating: "s", count: 512)
      ),
      .applied
    )
    XCTAssertEqual(
      operators.replaceCharacters(
        field: .search,
        range: NSRange(location: 512, length: 0),
        replacement: "x"
      ),
      .rejected(.byteLimit)
    )
    XCTAssertEqual(
      operators.replaceCharacters(
        field: .jsonPath,
        range: NSRange(location: 0, length: 0),
        replacement: String(repeating: "p", count: 256)
      ),
      .applied
    )
    XCTAssertEqual(
      operators.replaceCharacters(
        field: .jsonComparison,
        range: NSRange(location: 0, length: 0),
        replacement: String(repeating: "v", count: 16 * 1_024)
      ),
      .applied
    )
    XCTAssertEqual(
      operators.replaceCharacters(
        field: .name,
        range: NSRange(location: 0, length: 0),
        replacement: String(repeating: "n", count: 80)
      ),
      .applied
    )
    XCTAssertEqual(
      operators.replaceCharacters(
        field: .name,
        range: NSRange(location: 80, length: 0),
        replacement: "x"
      ),
      .rejected(.scalarLimit)
    )
    XCTAssertEqual(
      operators.replaceCharacters(
        field: .name,
        range: NSRange(location: 0, length: 80),
        replacement: String(repeating: "é", count: 60)
      ),
      .applied
    )
    XCTAssertEqual(operators.name.utf8ByteCount, 120)
    XCTAssertEqual(
      operators.replaceCharacters(
        field: .name,
        range: NSRange(location: 60, length: 0),
        replacement: "x"
      ),
      .rejected(.byteLimit)
    )
    XCTAssertEqual(
      operators.replaceCharacters(
        field: .note,
        range: NSRange(location: 0, length: 0),
        replacement: String(repeating: "🙂", count: 4_096)
      ),
      .applied
    )
    XCTAssertEqual(operators.note.utf8ByteCount, 16 * 1_024)
    XCTAssertEqual(operators.note.unicodeScalarCount, 4_096)
    XCTAssertEqual(operators.annotation.maximumUTF8Bytes, 16 * 1_024)
    XCTAssertEqual(operators.annotation.maximumUnicodeScalars, 4_096)
    XCTAssertEqual(operators.search.diagnostics.fullValueRescanCount, 0)
    XCTAssertEqual(operators.note.diagnostics.fullValueRescanCount, 0)
    XCTAssertTrue(Mirror(reflecting: operators).children.isEmpty)
  }

  func testComposerPreparerReportsBoundedFailuresWithoutEncodingInvalidInput() throws {
    let runtimeLogicalID = UUID()
    let limits = EventValidationLimits.default
    func request(
      generation: UInt64,
      type: String,
      content: String,
      ttl: String
    ) -> ViewerComposerPreparationRequest {
      ViewerComposerPreparationRequest(
        token: ViewerComposerGenerationToken(
          runtimeLogicalID: runtimeLogicalID,
          generation: generation
        ),
        input: ViewerComposerInputSnapshot(
          eventType: type,
          contentJSON: content,
          ttlText: ttl,
          priority: .normal,
          policy: .normal,
          activeLimits: limits
        )
      )
    }
    let preparer = ViewerComposerPreparer()

    let invalidJSON = preparer.prepare(
      request(generation: 1, type: "control.test", content: "{", ttl: "60000")
    )
    guard case .failure(let invalidJSONError, let invalidJSONDiagnostics) = invalidJSON.outcome
    else { return XCTFail("Expected invalid JSON") }
    XCTAssertEqual(invalidJSONError, .invalidContent)
    XCTAssertEqual(invalidJSONDiagnostics.inputCopyCount, 1)
    XCTAssertEqual(invalidJSONDiagnostics.contentTraversalCount, 1)
    XCTAssertEqual(invalidJSONDiagnostics.draftValidationCount, 0)
    XCTAssertEqual(invalidJSONDiagnostics.encodeCount, 0)

    let reserved = preparer.prepare(
      request(
        generation: 2,
        type: "nearwire.control",
        content: #"{"value":1}"#,
        ttl: "60000"
      )
    )
    guard case .failure(let reservedError, let reservedDiagnostics) = reserved.outcome else {
      return XCTFail("Expected reserved Event type rejection")
    }
    XCTAssertEqual(reservedError, .invalidEventType)
    XCTAssertEqual(reservedDiagnostics.contentTraversalCount, 1)
    XCTAssertEqual(reservedDiagnostics.draftValidationCount, 0)
    XCTAssertEqual(reservedDiagnostics.encodeCount, 0)

    let invalidTTL = preparer.prepare(
      request(generation: 3, type: "control.test", content: #"{"value":1}"#, ttl: "0")
    )
    guard case .failure(let ttlError, let ttlDiagnostics) = invalidTTL.outcome else {
      return XCTFail("Expected TTL rejection")
    }
    XCTAssertEqual(ttlError, .invalidTTL)
    XCTAssertEqual(ttlDiagnostics.contentTraversalCount, 1)
    XCTAssertEqual(ttlDiagnostics.draftValidationCount, 0)
    XCTAssertEqual(ttlDiagnostics.encodeCount, 0)

    let cancelled = preparer.prepare(
      request(generation: 4, type: "control.test", content: #"{"value":1}"#, ttl: "1"),
      isCancelled: { true }
    )
    guard case .failure(let cancellationError, let cancellationDiagnostics) = cancelled.outcome
    else { return XCTFail("Expected cancellation") }
    XCTAssertEqual(cancellationError, .cancelled)
    XCTAssertEqual(cancellationDiagnostics, ViewerComposerPreparationDiagnostics())
  }

  @MainActor
  func testComposerPreparationReplacesOneGenerationAndCountsOneSuccessfulPipeline()
    async throws
  {
    let model = try ViewerControlComposerModel(
      runtimeLogicalID: UUID(),
      activeLimits: .default
    )
    XCTAssertEqual(
      model.replaceCharacters(
        field: .eventType,
        range: NSRange(location: 0, length: 0),
        replacement: "control.test"
      ),
      .applied
    )
    XCTAssertEqual(
      model.replaceCharacters(
        field: .content,
        range: NSRange(location: 0, length: 0),
        replacement: #"{"secret":"first-composer-secret"}"#
      ),
      .applied
    )
    XCTAssertEqual(
      model.replaceCharacters(
        field: .ttl,
        range: NSRange(location: 0, length: 0),
        replacement: "60000"
      ),
      .applied
    )
    model.setPriority(.high)
    model.setPolicy(.keepLatest)
    let firstRequest = model.makePreparationRequest()

    let queue = DispatchQueue(label: "com.nearwire.viewer.tests.composer-replacement")
    let gate = DispatchSemaphore(value: 0)
    queue.async { gate.wait() }
    let service = ViewerComposerPreparationService(queue: queue)
    let results = LockedComposerResultCollection()
    let completed = expectation(description: "Both composer generations completed")
    completed.expectedFulfillmentCount = 2
    service.submit(firstRequest) { result in
      results.append(result)
      completed.fulfill()
    }

    XCTAssertEqual(
      model.replaceCharacters(
        field: .content,
        range: NSRange(location: 0, length: model.content.utf16Count),
        replacement: #"{"secret":"second-composer-secret"}"#
      ),
      .applied
    )
    let secondRequest = model.makePreparationRequest()
    service.submit(secondRequest) { result in
      results.append(result)
      completed.fulfill()
    }
    XCTAssertEqual(results.values.count, 1)
    XCTAssertEqual(service.pendingWorkCount, 1)
    XCTAssertEqual(service.retainedRequestLimit, 2)
    XCTAssertEqual(service.retainedRequestCountForTesting, 1)
    gate.signal()
    await fulfillment(of: [completed], timeout: 2)

    let firstResult = try XCTUnwrap(results.values.first { $0.token == firstRequest.token })
    let secondResult = try XCTUnwrap(results.values.first { $0.token == secondRequest.token })
    guard case .failure(let firstError, let firstDiagnostics) = firstResult.outcome else {
      return XCTFail("Expected replaced generation to cancel")
    }
    XCTAssertEqual(firstError, .cancelled)
    XCTAssertEqual(firstDiagnostics, ViewerComposerPreparationDiagnostics())
    XCTAssertFalse(model.apply(firstResult))

    guard case .success(let prepared, let diagnostics) = secondResult.outcome else {
      return XCTFail("Expected latest composer generation to succeed")
    }
    XCTAssertEqual(diagnostics.inputCopyCount, 1)
    XCTAssertEqual(diagnostics.contentTraversalCount, 1)
    XCTAssertEqual(diagnostics.draftValidationCount, 1)
    XCTAssertEqual(diagnostics.encodeCount, 1)
    XCTAssertEqual(prepared.draft.type.rawValue, "control.test")
    XCTAssertEqual(prepared.draft.priority, .high)
    XCTAssertEqual(prepared.draft.ttl.milliseconds, 60_000)
    XCTAssertEqual(prepared.policy, .keepLatest)
    XCTAssertEqual(
      String(describing: prepared.queuePolicy), "EventQueuePolicy.keepLatest(redacted)")
    XCTAssertLessThanOrEqual(
      prepared.deterministicEncodedByteCount,
      ViewerPreparedControlEvent.maximumEncodedBytes
    )
    XCTAssertTrue(model.apply(secondResult))
    XCTAssertEqual(
      model.preparedEvent?.deterministicEncodedByteCount, prepared.deterministicEncodedByteCount)

    let redacted = [
      String(describing: model),
      String(reflecting: firstRequest),
      String(reflecting: secondRequest.input),
      String(reflecting: secondResult),
      String(reflecting: prepared),
    ].joined()
    XCTAssertFalse(redacted.contains("first-composer-secret"))
    XCTAssertFalse(redacted.contains("second-composer-secret"))
    XCTAssertTrue(Mirror(reflecting: secondResult).children.isEmpty)

    model.clear()
    XCTAssertEqual(model.eventType.value, "")
    XCTAssertEqual(model.content.value, "")
    XCTAssertEqual(model.ttl.value, "")
    XCTAssertNil(model.preparedEvent)
    XCTAssertNil(model.preparationFailure)
    XCTAssertFalse(model.apply(secondResult))
  }

  @MainActor
  func testApplicationCreatesOneRuntimeBundlePerStartAndCleansFailedRuntimeBeforeRetry()
    async throws
  {
    let created = expectation(description: "A fresh runtime bundle was created")
    created.expectedFulfillmentCount = 2
    let capture = LockedRuntimeComponentCapture()
    let generations = ViewerManagerGenerationSource()
    let model = ViewerApplicationModel(
      preferences: ViewerPreferences(requiresApproval: { false }, setRequiresApproval: { _ in }),
      dependencies: ViewerRuntimeDependencies(
        loadIdentity: { throw ViewerPairingCodeGenerationError() },
        resetTLSIdentity: {},
        resetAllIdentity: {},
        generatePairingCode: { try PairingCode("ABCDEF") },
        makeRuntimeComponents: { runtimeLogicalID in
          let components = ViewerRuntimeComponents.make(
            runtimeLogicalID: runtimeLogicalID,
            managerGeneration: generations.next()
          )
          capture.append(components)
          created.fulfill()
          return components
        }
      )
    )

    model.openWindow()
    await waitForStatus(.failed(.identityUnavailable), in: model)
    await waitUntilRuntimeCapture({ capture.count == 1 && capture.allLiveWindowsCleared })

    model.retry()
    await fulfillment(of: [created], timeout: 1)
    await waitForStatus(.failed(.identityUnavailable), in: model)
    await waitUntilRuntimeCapture({ capture.count == 2 && capture.allLiveWindowsCleared })

    XCTAssertEqual(capture.managerGenerations, [1, 2])
    XCTAssertEqual(Set(capture.runtimeLogicalIDs).count, 2)
    _ = await model.prepareForTermination()
    XCTAssertEqual(model.status, .stopped)
  }

  @MainActor
  func testSynchronousLocalNetworkListenerFailureKeepsRecoverableCategory() async throws {
    let listenerAttempted = expectation(description: "Listener creation attempted")
    let model = ViewerApplicationModel(
      preferences: ViewerPreferences(requiresApproval: { false }, setRequiresApproval: { _ in }),
      dependencies: ViewerRuntimeDependencies(
        loadIdentity: {
          ViewerPreparedIdentity(
            installationID: try EndpointID(rawValue: "viewer-test"),
            makeListener: { _ in
              listenerAttempted.fulfill()
              throw SecureTransportError(
                code: .localNetworkUnavailable,
                message: "Raw construction detail"
              )
            }
          )
        },
        resetTLSIdentity: {},
        resetAllIdentity: {},
        generatePairingCode: { try PairingCode("ABCDEF") }
      )
    )

    model.openWindow()
    await fulfillment(of: [listenerAttempted], timeout: 1)
    await Task.yield()
    XCTAssertEqual(model.status, .failed(.localNetworkUnavailable))
  }

  func testInjectedIdentityLifecycleCreatesReloadsRepairsAndResetsExactItems() throws {
    let persistence = FakeIdentityPersistence()
    let builder = makeDeterministicCertificateBuilder(year: 2039)
    let store = ViewerIdentityStore(
      names: .isolated(),
      certificateBuilder: builder,
      persistence: persistence
    )

    let first = try store.loadOrCreateMaterial()
    let firstCertificate = SecCertificateCopyData(first.certificate) as Data
    let second = try store.loadOrCreateMaterial()
    XCTAssertEqual(first.installationID, second.installationID)
    XCTAssertEqual(firstCertificate, SecCertificateCopyData(second.certificate) as Data)
    XCTAssertEqual(persistence.callCount(.createPrivateKey), 1)
    XCTAssertEqual(persistence.certificateCount, 1)

    persistence.corruptTLSMetadata()
    let repaired = try store.loadOrCreateMaterial()
    XCTAssertEqual(first.installationID, repaired.installationID)
    XCTAssertNotEqual(firstCertificate, SecCertificateCopyData(repaired.certificate) as Data)
    XCTAssertEqual(persistence.callCount(.createPrivateKey), 2)
    XCTAssertEqual(persistence.certificateCount, 2)

    try store.resetTLSIdentity()
    XCTAssertTrue(persistence.hasGenericPassword("installation-id"))
    XCTAssertFalse(persistence.hasGenericPassword("tls-metadata"))
    XCTAssertFalse(persistence.hasPrivateKey)
    XCTAssertEqual(persistence.certificateCount, 1)

    let afterTLSReset = try store.loadOrCreateMaterial()
    XCTAssertEqual(first.installationID, afterTLSReset.installationID)
    try store.resetAllIdentity()
    XCTAssertFalse(persistence.hasGenericPassword("installation-id"))
    XCTAssertFalse(persistence.hasGenericPassword("tls-metadata"))
    XCTAssertFalse(persistence.hasPrivateKey)

    let afterFullReset = try store.loadOrCreateMaterial()
    XCTAssertNotEqual(first.installationID, afterFullReset.installationID)
  }

  func testIdentityAssemblyFailsClosedWhenExactPersistenceLookupFails() {
    let persistence = FakeIdentityPersistence()
    let store = ViewerIdentityStore(
      names: .isolated(),
      certificateBuilder: makeDeterministicCertificateBuilder(year: 2039),
      persistence: persistence
    )

    XCTAssertThrowsError(try store.loadOrCreate())
    XCTAssertEqual(persistence.callCount(.copyIdentity), 1)
  }

  func testExplicitIdentityResetRequiresCompleteOwnedTupleAndPreservesForeignCertificate() throws {
    let builder = makeDeterministicCertificateBuilder(year: 2039)

    do {
      let persistence = FakeIdentityPersistence()
      let store = ViewerIdentityStore(
        names: .isolated(),
        certificateBuilder: builder,
        persistence: persistence
      )
      _ = try store.loadOrCreateMaterial()
      persistence.removePrivateKey()

      XCTAssertThrowsError(try store.resetTLSIdentity())
      XCTAssertEqual(persistence.certificateCount, 1)
      XCTAssertTrue(persistence.hasGenericPassword("tls-metadata"))
      XCTAssertEqual(persistence.callCount(.deleteCertificate), 0)
    }

    do {
      let persistence = FakeIdentityPersistence()
      let store = ViewerIdentityStore(
        names: .isolated(),
        certificateBuilder: builder,
        persistence: persistence
      )
      _ = try store.loadOrCreateMaterial()
      persistence.replacePrivateKey(try builder.createEphemeralPrivateKey())

      XCTAssertThrowsError(try store.resetTLSIdentity())
      XCTAssertEqual(persistence.certificateCount, 1)
      XCTAssertTrue(persistence.hasGenericPassword("tls-metadata"))
      XCTAssertEqual(persistence.callCount(.deleteCertificate), 0)
    }

    do {
      let persistence = FakeIdentityPersistence()
      let store = ViewerIdentityStore(
        names: .isolated(),
        certificateBuilder: builder,
        persistence: persistence
      )
      _ = try store.loadOrCreateMaterial()
      let foreignKey = try builder.createEphemeralPrivateKey()
      let foreign = try builder.build(privateKey: foreignKey)
      let label = "NearWire Viewer Foreign Fixture"
      let reference = try persistence.addForeignCertificate(foreign.certificate, label: label)
      let foreignPublicKey = try XCTUnwrap(SecCertificateCopyKey(foreign.certificate))
      try persistence.pointMetadata(
        to: reference,
        certificate: foreign.certificate,
        label: label,
        publicKey: foreignPublicKey
      )
      let deleteCount = persistence.callCount(.deleteCertificate)

      XCTAssertThrowsError(try store.resetTLSIdentity())
      XCTAssertEqual(persistence.certificateCount, 2)
      XCTAssertEqual(persistence.callCount(.deleteCertificate), deleteCount)
      XCTAssertTrue(persistence.hasPrivateKey)
      XCTAssertTrue(persistence.hasGenericPassword("tls-metadata"))
    }
  }

  func testExplicitIdentityResetReportsEveryPartialDeleteFailure() throws {
    let builder = makeDeterministicCertificateBuilder(year: 2039)

    do {
      let persistence = FakeIdentityPersistence()
      let store = ViewerIdentityStore(
        names: .isolated(),
        certificateBuilder: builder,
        persistence: persistence
      )
      _ = try store.loadOrCreateMaterial()
      persistence.failNext(.deleteCertificate)
      XCTAssertThrowsError(try store.resetTLSIdentity())
      XCTAssertEqual(persistence.certificateCount, 1)
      XCTAssertTrue(persistence.hasPrivateKey)
      XCTAssertTrue(persistence.hasGenericPassword("tls-metadata"))
    }

    do {
      let persistence = FakeIdentityPersistence()
      let store = ViewerIdentityStore(
        names: .isolated(),
        certificateBuilder: builder,
        persistence: persistence
      )
      _ = try store.loadOrCreateMaterial()
      persistence.failNext(.deletePrivateKey)
      XCTAssertThrowsError(try store.resetTLSIdentity())
      XCTAssertEqual(persistence.certificateCount, 0)
      XCTAssertTrue(persistence.hasPrivateKey)
      XCTAssertTrue(persistence.hasGenericPassword("tls-metadata"))
    }

    do {
      let persistence = FakeIdentityPersistence()
      let store = ViewerIdentityStore(
        names: .isolated(),
        certificateBuilder: builder,
        persistence: persistence
      )
      _ = try store.loadOrCreateMaterial()
      persistence.failNext(.deleteGenericPassword)
      XCTAssertThrowsError(try store.resetTLSIdentity())
      XCTAssertEqual(persistence.certificateCount, 0)
      XCTAssertFalse(persistence.hasPrivateKey)
      XCTAssertTrue(persistence.hasGenericPassword("tls-metadata"))
    }
  }

  func testCertificateBuilderSupportsUTCAndGeneralizedTimeValidityWindows() throws {
    let beforeTransition = makeDeterministicCertificateBuilder(year: 2039)
    let afterTransition = makeDeterministicCertificateBuilder(year: 2041)
    let firstKey = try beforeTransition.createEphemeralPrivateKey()
    let secondKey = try afterTransition.createEphemeralPrivateKey()

    let first = try beforeTransition.build(privateKey: firstKey)
    let second = try afterTransition.build(privateKey: secondKey)
    let firstProfile = try beforeTransition.validate(
      certificate: first.certificate,
      privateKey: firstKey,
      at: beforeTransition.now(),
      requireRenewalHeadroom: false
    )
    let secondProfile = try afterTransition.validate(
      certificate: second.certificate,
      privateKey: secondKey,
      at: afterTransition.now(),
      requireRenewalHeadroom: false
    )

    XCTAssertEqual(calendarYear(firstProfile.notAfter), 2048)
    XCTAssertEqual(calendarYear(secondProfile.notAfter), 2050)
    XCTAssertTrue(first.der.contains(0x17))
    XCTAssertTrue(second.der.contains(0x18))
  }

  func testDERTimeUsesCanonicalTransitionAndRejectsEarlyGeneralizedTime() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let lastUTC = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2049, month: 12, day: 31))
    )
    let firstGeneralized = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2050, month: 1, day: 1))
    )

    let utc = try ViewerDER.time(lastUTC)
    let generalized = try ViewerDER.time(firstGeneralized)
    XCTAssertEqual(utc.first, 0x17)
    XCTAssertEqual(generalized.first, 0x18)
    XCTAssertEqual(calendarYear(try ViewerDER.parseTime(utc)), 2049)
    XCTAssertEqual(calendarYear(try ViewerDER.parseTime(generalized)), 2050)

    let noncanonical2049 = ViewerDER.tagged(0x18, Data("20491231235959Z".utf8))
    let noncanonical1949 = ViewerDER.tagged(0x18, Data("19491231235959Z".utf8))
    XCTAssertThrowsError(try ViewerDER.parseTime(noncanonical2049))
    XCTAssertThrowsError(try ViewerDER.parseTime(noncanonical1949))
  }

  func testLoadedPrivateKeyValidationRequiresP256AndNonexportability() {
    let valid: [CFString: Any] = [kSecAttrKeySizeInBits: 256]
    XCTAssertTrue(
      ViewerIdentityStore.hasRequiredLoadedPrivateKeyProperties(
        valid,
        isExternallyRepresentable: false
      )
    )
    XCTAssertFalse(
      ViewerIdentityStore.hasRequiredLoadedPrivateKeyProperties(
        [:],
        isExternallyRepresentable: false
      )
    )
    XCTAssertFalse(
      ViewerIdentityStore.hasRequiredLoadedPrivateKeyProperties(
        valid,
        isExternallyRepresentable: true
      )
    )
  }

  private func makeAppHelloFrame(installationID: String) throws -> Data {
    let hello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .app,
      installationID: EndpointID(rawValue: installationID),
      displayName: "Demo App"
    )
    return try WirePreHandshakeCodec().encode(hello)
  }

  private func assertPrivateKeyCanSign(_ privateKey: SecKey) throws {
    var error: Unmanaged<CFError>?
    let signature = SecKeyCreateSignature(
      privateKey,
      .ecdsaSignatureMessageX962SHA256,
      Data("NearWire stable signer update probe".utf8) as CFData,
      &error
    )
    if let error { throw error.takeRetainedValue() }
    XCTAssertNotNil(signature)
  }

  private func makeDeterministicCertificateBuilder(year: Int) -> ViewerCertificateBuilder {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = calendar.date(from: DateComponents(year: year, month: 1, day: 2))!
    return ViewerCertificateBuilder(
      randomBytes: { count in Array((1...count).map(UInt8.init)) },
      now: { date }
    )
  }

  private func makeMemorySessionFixture() throws -> (
    window: ViewerLiveEventWindow,
    observation: ViewerCommittedEventObservation
  ) {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let context = try makeObservationContext(
      connectionID: connectionID,
      displayName: "Memory Session fixture"
    )
    let window = ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
    window.sessionStarted(
      try ViewerFrozenSessionMetadata(context: context, nickname: nil),
      connectionID: connectionID
    )
    let correlationID = EventID()
    let envelope = try makeObservationEnvelope(
      content: .object([
        "message": .string("Round trip"),
        "count": .integer(7),
      ]),
      createdAt: Date(timeIntervalSince1970: 2_026),
      monotonicTimestampNanoseconds: 20_260,
      sessionEpoch: SessionEpoch(),
      sequence: 7,
      causality: EventCausality(correlationID: correlationID)
    )
    let observation = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: envelope,
      viewerWallMilliseconds: 2_026_000,
      viewerMonotonicNanoseconds: 20_260,
      deterministicEventBytes: 256,
      initialDisposition: .buffered
    )
    XCTAssertEqual(window.offer(observation), .accepted)
    window.waitForProjectionForTesting()
    XCTAssertEqual(window.snapshot().events.count, 1)
    return (window, observation)
  }

  private func makeTemporaryTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NearWire-ViewerFoundationTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false
    )
    return directory
  }

  private func prepareMemorySessionExport(
    using transfer: ViewerMemorySessionTransferService
  ) async throws -> ViewerMemorySessionExportTicket {
    let result: Result<ViewerMemorySessionExportTicket, ViewerExplorerFailure> =
      await withCheckedContinuation { continuation in
        _ = transfer.prepareExport { result in
          continuation.resume(returning: result)
        }
      }
    return try result.get()
  }

  private func executeMemorySessionExport(
    _ ticket: ViewerMemorySessionExportTicket,
    using transfer: ViewerMemorySessionTransferService,
    to destination: URL
  ) async throws {
    let result: Result<Void, ViewerExplorerFailure> = await withCheckedContinuation {
      continuation in
      _ = transfer.executeExport(ticket, to: destination) { result in
        continuation.resume(returning: result)
      }
    }
    try result.get()
  }

  private func importMemorySession(
    using transfer: ViewerMemorySessionTransferService,
    from source: URL
  ) async -> Result<Void, ViewerWorkspaceMutationFailure> {
    await withCheckedContinuation { continuation in
      transfer.importCurrentSession(from: source) { result in
        continuation.resume(returning: result)
      }
    }
  }

  private func assertMemorySession(
    _ window: ViewerLiveEventWindow,
    stillContains observation: ViewerCommittedEventObservation,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    window.waitForProjectionForTesting()
    let snapshot = window.snapshot()
    XCTAssertEqual(snapshot.sessions.count, 1, file: file, line: line)
    XCTAssertEqual(snapshot.events.count, 1, file: file, line: line)
    XCTAssertEqual(
      snapshot.events.first?.observation.envelope.id,
      observation.envelope.id,
      file: file,
      line: line
    )
  }

  private func makeObservationContext(
    connectionID: UUID,
    displayName: String
  ) throws -> ViewerAdmissionSessionContext {
    let appID = try EndpointID(rawValue: "observation-app")
    let viewerID = try EndpointID(rawValue: "observation-viewer")
    let appHello = try WireHello(
      productVersion: WireProductVersion("1.0.0"),
      role: .app,
      installationID: appID,
      displayName: displayName,
      applicationIdentifier: "com.nearwire.observation",
      applicationVersion: "1.0"
    )
    let viewerHello = try WireHello(
      productVersion: WireProductVersion("1.0.0"),
      role: .viewer,
      installationID: viewerID
    )
    return ViewerAdmissionSessionContext(
      connectionID: connectionID,
      appHello: appHello,
      viewerHello: viewerHello,
      negotiation: try WireNegotiator.negotiate(local: viewerHello, remote: appHello),
      receiveChunkBytes: 64 * 1_024
    )
  }

  private func makeObservationEnvelope(
    id: EventID = EventID(),
    typeRawValue: String = "test.observation",
    eventType: EventType? = nil,
    content: JSONValue,
    createdAt: Date,
    monotonicTimestampNanoseconds: UInt64 = 500,
    sessionEpoch: SessionEpoch,
    sequence: UInt64 = 0,
    priority: EventPriority = .normal,
    ttl: EventTTL = .default,
    causality: EventCausality = EventCausality(),
    schemaVersion: EventSchemaVersion = .current
  ) throws -> EventEnvelope {
    let appID = try EndpointID(rawValue: "observation-app")
    let viewerID = try EndpointID(rawValue: "observation-viewer")
    return try EventEnvelope(
      id: id,
      type: eventType ?? EventType.user(typeRawValue),
      content: content,
      createdAt: createdAt,
      monotonicTimestampNanoseconds: monotonicTimestampNanoseconds,
      source: EventEndpoint(role: .app, id: appID),
      target: EventEndpoint(role: .viewer, id: viewerID),
      direction: .appToViewer,
      sessionEpoch: sessionEpoch,
      sequence: EventSequence(sequence),
      priority: priority,
      ttl: ttl,
      causality: causality,
      schemaVersion: schemaVersion
    )
  }

  private func makeRendererBuffer(
    rowID: Int64,
    eventType: String,
    content: Data
  ) -> ViewerCanonicalEventDetailBuffer {
    try! ViewerCanonicalEventDetailBuffer(
      metadata: ViewerInspectorEventMetadata(
        eventUUID: "renderer-event-\(rowID)",
        eventType: eventType,
        deviceLogicalID: UUID(),
        deviceAlias: "App 00000001",
        connectionAlias: "connection-1",
        direction: "appToViewer",
        wireSequence: UInt64(rowID),
        priority: "normal",
        createdWallMilliseconds: rowID,
        viewerWallMilliseconds: rowID,
        viewerMonotonicNanoseconds: UInt64(rowID),
        originMonotonicNanoseconds: UInt64(rowID),
        ttlMilliseconds: 60_000,
        schemaVersion: 1,
        disposition: "buffered",
        correlationEventUUID: nil,
        replyToEventUUID: nil,
        hasGap: false,
        hasDrop: false,
        hasPresentationConflict: false,
        sessionEnded: false
      ),
      content: content
    )
  }

  private func rendererJournalKey(_ rowID: Int64) -> ViewerEventJournalKey {
    ViewerEventJournalKey(
      runtimeLogicalID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      connectionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      direction: .appToViewer,
      wireSequence: UInt64(rowID)
    )
  }

  private func calendarYear(_ date: Date) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.component(.year, from: date)
  }

  @MainActor
  private func waitForStatus(
    _ expected: ViewerApplicationModel.Status,
    in model: ViewerApplicationModel,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    if model.status == expected { return }
    let reached = expectation(description: "Application model reached expected status")
    let observation = model.$status.sink { status in
      if status == expected { reached.fulfill() }
    }
    await fulfillment(of: [reached], timeout: 1)
    withExtendedLifetime(observation) {}
    XCTAssertEqual(model.status, expected, file: file, line: line)
  }

  @MainActor
  private func waitUntilRuntimeCapture(
    _ condition: @escaping () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0..<1_000 {
      if condition() { return }
      await Task.yield()
    }
    XCTAssertTrue(condition(), file: file, line: line)
  }

  @MainActor
  private func waitUntilExplorer(
    _ condition: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0..<1_000 {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("Timed out waiting for Explorer state", file: file, line: line)
  }

  @MainActor
  private func waitUntilPerformanceDashboard(
    _ condition: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0..<1_000 {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("Timed out waiting for Performance dashboard state", file: file, line: line)
  }

  private func waitForAdmissionOccupancy(
    _ expectedCount: Int,
    in manager: ViewerAdmissionManager,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0..<1_000 {
      if manager.occupiedCount == expectedCount { return }
      await Task.yield()
    }
    XCTAssertEqual(manager.occupiedCount, expectedCount, file: file, line: line)
  }

  @MainActor
  private func makeApplicationModel(
    listenerFactory: LockedListenerFactory,
    pairingCodes: LockedPairingCodeSequence
  ) -> ViewerApplicationModel {
    ViewerApplicationModel(
      preferences: ViewerPreferences(requiresApproval: { false }, setRequiresApproval: { _ in }),
      dependencies: ViewerRuntimeDependencies(
        loadIdentity: {
          ViewerPreparedIdentity(
            installationID: try EndpointID(rawValue: "viewer-test"),
            makeListener: { advertisement in try listenerFactory.next(advertisement) }
          )
        },
        resetTLSIdentity: {},
        resetAllIdentity: {},
        generatePairingCode: { try pairingCodes.next() }
      )
    )
  }
}

@MainActor
private func descendantViews<ViewType: NSView>(
  of type: ViewType.Type,
  in root: NSView
) -> [ViewType] {
  root.subviews.flatMap { child in
    var matches = descendantViews(of: type, in: child)
    if let match = child as? ViewType { matches.insert(match, at: 0) }
    return matches
  }
}

@MainActor
private func renderedPNGData(of view: NSView) -> Data? {
  guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
    return nil
  }
  view.cacheDisplay(in: view.bounds, to: representation)
  return representation.representation(using: .png, properties: [:])
}

private final class LockedTestCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  func increment() {
    lock.lock()
    storage += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private final class BlockingViewerOperationGate: @unchecked Sendable {
  private let lock = NSLock()
  private let entered = DispatchSemaphore(value: 0)
  private let resume = DispatchSemaphore(value: 0)
  private var shouldBlock = true

  func run() {
    lock.lock()
    let blocks = shouldBlock
    shouldBlock = false
    lock.unlock()
    guard blocks else { return }
    entered.signal()
    _ = resume.wait(timeout: .now() + 5)
  }

  func waitUntilEntered() -> DispatchTimeoutResult {
    entered.wait(timeout: .now() + 2)
  }

  func release() {
    resume.signal()
  }
}

private final class BlockingViewerMonotonicClock: @unchecked Sendable {
  private let lock = NSLock()
  private let entered = DispatchSemaphore(value: 0)
  private let resume = DispatchSemaphore(value: 0)
  private var callCount = 0
  private var blocked = false

  var isBlocked: Bool {
    lock.lock()
    defer { lock.unlock() }
    return blocked
  }

  func now() -> UInt64 {
    lock.lock()
    callCount += 1
    let shouldBlock = callCount == 2
    if shouldBlock { blocked = true }
    lock.unlock()
    if shouldBlock {
      entered.signal()
      resume.wait()
    }
    return 0
  }

  func waitUntilBlocked() -> DispatchTimeoutResult {
    entered.wait(timeout: .now() + 2)
  }

  func release() { resume.signal() }
}

extension ViewerPendingAppSummary {
  fileprivate static func fixture(name: String) -> ViewerPendingAppSummary {
    ViewerPendingAppSummary(
      id: UUID(),
      displayName: name,
      applicationIdentifier: nil,
      applicationVersion: nil,
      installationAlias: "App fixture",
      compatibilityStatus: "Compatible"
    )
  }
}

private final class LockedCoalescerBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: ViewerPendingCoalescer?

  func set(_ value: ViewerPendingCoalescer) {
    lock.lock()
    storage = value
    lock.unlock()
  }

  var value: ViewerPendingCoalescer? {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private final class LockedRendererResultCollection: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValues: [ViewerRendererPreparationResult] = []

  func append(_ value: ViewerRendererPreparationResult) {
    lock.lock()
    storedValues.append(value)
    lock.unlock()
  }

  var values: [ViewerRendererPreparationResult] {
    lock.lock()
    defer { lock.unlock() }
    return storedValues
  }
}

private final class LockedComposerResultCollection: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValues: [ViewerComposerPreparationResult] = []

  func append(_ value: ViewerComposerPreparationResult) {
    lock.lock()
    storedValues.append(value)
    lock.unlock()
  }

  var values: [ViewerComposerPreparationResult] {
    lock.lock()
    defer { lock.unlock() }
    return storedValues
  }
}

private final class LockedStringSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  func append(_ value: String) {
    lock.lock()
    storage.append(value)
    lock.unlock()
  }

  var values: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private final class FakeViewerSecureListener: ViewerSecureListener, @unchecked Sendable {
  private let lock = NSLock()
  private let eventsOnStart: [SecureViewerListenerEvent]
  private let onCancel: @Sendable () -> Void
  private let onStart: @Sendable () -> Void
  private var eventHandler: SecureViewerListener.EventHandler?
  private var cancellations = 0

  init(
    eventsOnStart: [SecureViewerListenerEvent] = [],
    onCancel: @escaping @Sendable () -> Void = {},
    onStart: @escaping @Sendable () -> Void = {}
  ) {
    self.eventsOnStart = eventsOnStart
    self.onCancel = onCancel
    self.onStart = onStart
  }

  func start(
    queue: DispatchQueue,
    eventHandler: @escaping SecureViewerListener.EventHandler
  ) throws {
    lock.lock()
    self.eventHandler = eventHandler
    let events = eventsOnStart
    lock.unlock()
    onStart()
    for event in events { eventHandler(event) }
  }

  func cancel() {
    lock.lock()
    cancellations += 1
    lock.unlock()
    onCancel()
  }

  func emit(_ event: SecureViewerListenerEvent) {
    lock.lock()
    let eventHandler = eventHandler
    lock.unlock()
    eventHandler?(event)
  }

  var cancelCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return cancellations
  }
}

private final class LockedListenerFactory: @unchecked Sendable {
  private let lock = NSLock()
  private var listeners: [FakeViewerSecureListener]
  private var storedAdvertisements: [SecureViewerServiceAdvertisement] = []

  init(_ listeners: [FakeViewerSecureListener]) {
    self.listeners = listeners
  }

  func next(_ advertisement: SecureViewerServiceAdvertisement) throws -> any ViewerSecureListener {
    lock.lock()
    defer { lock.unlock() }
    guard !listeners.isEmpty else { throw ViewerTestError.exhausted }
    storedAdvertisements.append(advertisement)
    return listeners.removeFirst()
  }

  var advertisements: [SecureViewerServiceAdvertisement] {
    lock.lock()
    defer { lock.unlock() }
    return storedAdvertisements
  }
}

private final class LockedPairingCodeSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String]
  private var requests = 0

  init(_ values: [String]) {
    self.values = values
  }

  func next() throws -> PairingCode {
    lock.lock()
    defer { lock.unlock() }
    requests += 1
    guard !values.isEmpty else { throw ViewerPairingCodeGenerationError() }
    return try PairingCode(values.removeFirst())
  }

  var requestCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }
}

private enum ViewerTestError: Error {
  case exhausted
  case invalidProbeConfiguration
  case signingMetadataUnavailable
}

private enum StableSignerProbePhase: String {
  case create
  case deny
  case verify
}

private struct StableSignerProbeFingerprint: Codable, Equatable {
  let teamIdentifier: String
  let certificateHash: Data
  let designatedRequirement: String
}

private struct StableSignerProbeRecord: Codable {
  let installationID: String
  let certificateHash: Data
  let certificatePersistentReference: Data
  let signer: StableSignerProbeFingerprint
  let codeDirectoryHash: Data
  let bundleVersion: String
  let buildID: String
  let productPath: String
}

private final class FakeAdmissionChannel: ViewerAdmissionChannel, @unchecked Sendable {
  private let lock = NSLock()
  private let supportsReceivePause: Bool
  private let onSend: @Sendable (Data) -> Void
  private let onStart: @Sendable () -> Void
  private let onCancel: @Sendable () -> Void
  private let cancelOperation: @Sendable () async -> Void
  private var payloads: [Data] = []
  private var starts = 0
  private var cancellations = 0

  init(
    supportsReceivePause: Bool = true,
    onSend: @escaping @Sendable (Data) -> Void = { _ in },
    onStart: @escaping @Sendable () -> Void = {},
    onCancel: @escaping @Sendable () -> Void = {},
    cancelOperation: @escaping @Sendable () async -> Void = {}
  ) {
    self.supportsReceivePause = supportsReceivePause
    self.onSend = onSend
    self.onStart = onStart
    self.onCancel = onCancel
    self.cancelOperation = cancelOperation
  }

  func admitSend(_ data: Data) throws {
    lock.lock()
    payloads.append(data)
    lock.unlock()
    onSend(data)
  }

  func claimReceivePause() -> SecureReceivePauseToken? {
    guard supportsReceivePause else { return nil }
    return SecureReceivePauseToken { _ in }
  }

  func start() async throws {
    recordStart()
    onStart()
  }

  func cancel() async {
    await cancelOperation()
    recordCancellation()
    onCancel()
  }

  private func recordStart() {
    lock.lock()
    starts += 1
    lock.unlock()
  }

  private func recordCancellation() {
    lock.lock()
    cancellations += 1
    lock.unlock()
  }

  var sentPayloads: [Data] {
    lock.lock()
    defer { lock.unlock() }
    return payloads
  }

  var startCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return starts
  }

  var cancelCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return cancellations
  }
}

private final class FakeIncomingConnection: ViewerIncomingConnection, @unchecked Sendable {
  let channel: FakeAdmissionChannel
  private let lock = NSLock()
  private var handler: SecureByteChannel.EventHandler?
  private var claims = 0
  private var rejections = 0
  private let beforeClaim: @Sendable () -> Void

  init(
    channel: FakeAdmissionChannel,
    beforeClaim: @escaping @Sendable () -> Void = {}
  ) {
    self.channel = channel
    self.beforeClaim = beforeClaim
  }

  func makeAdmissionChannel(
    queue: DispatchQueue,
    eventHandler: @escaping SecureByteChannel.EventHandler
  ) throws -> any ViewerAdmissionChannel {
    beforeClaim()
    lock.lock()
    claims += 1
    handler = eventHandler
    lock.unlock()
    return channel
  }

  func reject() {
    lock.lock()
    rejections += 1
    lock.unlock()
  }

  func emit(_ event: SecureByteChannelEvent) {
    lock.lock()
    let handler = handler
    lock.unlock()
    handler?(event)
  }

  var claimCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return claims
  }

  var rejectionCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return rejections
  }
}

private final class AsyncTestGate: @unchecked Sendable {
  private let lock = NSLock()
  private let entered = DispatchSemaphore(value: 0)
  private var isOpen = false
  private var enteredCount = 0
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    markEntered()
    entered.signal()
    await withCheckedContinuation { continuation in
      lock.lock()
      if isOpen {
        lock.unlock()
        continuation.resume()
      } else {
        continuations.append(continuation)
        lock.unlock()
      }
    }
  }

  var hasEntered: Bool {
    lock.lock()
    defer { lock.unlock() }
    return enteredCount > 0
  }

  private func markEntered() {
    lock.lock()
    enteredCount += 1
    lock.unlock()
  }

  func waitUntilEntered() {
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
  }

  func waitUntilEntered(count: Int) {
    for _ in 0..<count { waitUntilEntered() }
  }

  func open() {
    lock.lock()
    guard !isOpen else {
      lock.unlock()
      return
    }
    isOpen = true
    let continuations = continuations
    self.continuations.removeAll()
    lock.unlock()
    for continuation in continuations { continuation.resume() }
  }
}

private final class LockedUInt64Collection: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValues: [UInt64] = []

  func append(_ value: UInt64) {
    lock.lock()
    storedValues.append(value)
    lock.unlock()
  }

  var values: [UInt64] {
    lock.lock()
    defer { lock.unlock() }
    return storedValues
  }
}

private final class ManualLiveRefreshScheduler: @unchecked Sendable {
  private struct Job {
    let delay: UInt64
    let action: @Sendable () -> Void
  }

  private let lock = NSLock()
  private var currentNanoseconds: UInt64 = 0
  private var jobs: [Job] = []

  var value: ViewerLiveRefreshScheduler {
    ViewerLiveRefreshScheduler(
      now: { [weak self] in self?.now() ?? 0 },
      scheduleOnMain: { [weak self] delay, action in self?.schedule(delay: delay, action: action) }
    )
  }

  var pendingCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return jobs.count
  }

  var nextDelay: UInt64? {
    lock.lock()
    defer { lock.unlock() }
    return jobs.first?.delay
  }

  func runNext() {
    let job: Job?
    lock.lock()
    if jobs.isEmpty {
      job = nil
    } else {
      job = jobs.removeFirst()
      if let job {
        let (advanced, overflow) = currentNanoseconds.addingReportingOverflow(job.delay)
        currentNanoseconds = overflow ? UInt64.max : advanced
      }
    }
    lock.unlock()
    job?.action()
  }

  private func now() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return currentNanoseconds
  }

  private func schedule(delay: UInt64, action: @escaping @Sendable () -> Void) {
    lock.lock()
    jobs.append(Job(delay: delay, action: action))
    lock.unlock()
  }
}

private final class SteppingNanosecondClock: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UInt64]
  private var last: UInt64

  init(values: [UInt64]) {
    self.values = values
    last = values.last ?? 0
  }

  func now() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    guard !values.isEmpty else { return last }
    let value = values.removeFirst()
    last = value
    return value
  }
}

private final class LockedRuntimeComponentCapture: @unchecked Sendable {
  private struct Entry {
    let runtimeLogicalID: UUID
    let managerGeneration: UInt64
    let liveWindow: ViewerLiveEventWindow
  }

  private let lock = NSLock()
  private var entries: [Entry] = []

  func append(_ components: ViewerRuntimeComponents) {
    guard let liveWindow = components.liveObservations as? ViewerLiveEventWindow else { return }
    lock.lock()
    entries.append(
      Entry(
        runtimeLogicalID: components.runtimeLogicalID,
        managerGeneration: components.managerGeneration,
        liveWindow: liveWindow
      )
    )
    lock.unlock()
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return entries.count
  }

  var runtimeLogicalIDs: [UUID] {
    lock.lock()
    defer { lock.unlock() }
    return entries.map(\.runtimeLogicalID)
  }

  var managerGenerations: [UInt64] {
    lock.lock()
    defer { lock.unlock() }
    return entries.map(\.managerGeneration)
  }

  var allLiveWindowsCleared: Bool {
    lock.lock()
    let windows = entries.map(\.liveWindow)
    lock.unlock()
    return windows.allSatisfy(\.isCleared)
  }
}

private final class ManualAdmissionScheduler: @unchecked Sendable {
  private struct Waiter {
    let id: UUID
    let deadline: UInt64
    let continuation: CheckedContinuation<Void, Error>
  }

  private let lock = NSLock()
  private let scheduled = DispatchSemaphore(value: 0)
  private var current: UInt64 = 1
  private var waiters: [Waiter] = []
  private var cancelled: Set<UUID> = []

  var scheduler: ViewerAdmissionScheduler {
    ViewerAdmissionScheduler(
      now: { [weak self] in self?.now ?? 0 },
      sleep: { [weak self] duration in
        guard let self else { throw CancellationError() }
        try await self.sleep(duration)
      }
    )
  }

  var now: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func advance(by duration: UInt64) {
    lock.lock()
    current &+= duration
    let ready = waiters.filter { $0.deadline <= current }
    waiters.removeAll { $0.deadline <= current }
    lock.unlock()
    for waiter in ready { waiter.continuation.resume() }
  }

  func waitUntilScheduled() {
    XCTAssertEqual(scheduled.wait(timeout: .now() + 1), .success)
  }

  private func sleep(_ duration: UInt64) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        lock.lock()
        if cancelled.remove(id) != nil || Task.isCancelled {
          lock.unlock()
          continuation.resume(throwing: CancellationError())
          return
        }
        let deadline = current &+ duration
        waiters.append(Waiter(id: id, deadline: deadline, continuation: continuation))
        lock.unlock()
        scheduled.signal()
      }
    } onCancel: {
      lock.lock()
      if let index = waiters.firstIndex(where: { $0.id == id }) {
        let waiter = waiters.remove(at: index)
        lock.unlock()
        waiter.continuation.resume(throwing: CancellationError())
      } else {
        cancelled.insert(id)
        lock.unlock()
      }
    }
  }
}

private final class LockedHandleBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: ViewerAdmissionHandle?

  func set(_ value: ViewerAdmissionHandle) {
    lock.lock()
    storage = value
    lock.unlock()
  }

  var value: ViewerAdmissionHandle? {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private final class LockedHandleCollection: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [ViewerAdmissionHandle] = []

  @discardableResult
  func append(_ value: ViewerAdmissionHandle) -> Int {
    lock.lock()
    storage.append(value)
    let count = storage.count
    lock.unlock()
    return count
  }

  var values: [ViewerAdmissionHandle] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private final class FakeAdmissionHandoffOwner: ViewerAdmissionHandoffOwning,
  ViewerSessionControlling, @unchecked Sendable
{
  let runtimeLogicalID: UUID
  let managerGeneration: UInt64
  private let lock = NSLock()
  private let onTransfer: @Sendable (ViewerAdmissionHandle) -> Void
  private let shutdownOperation: @Sendable () async -> Void
  private var handles: [ViewerAdmissionHandle] = []
  private var shuttingDown = false
  private var shutdownTask: Task<Void, Never>?

  init(
    runtimeLogicalID: UUID = UUID(),
    managerGeneration: UInt64 = 1,
    onTransfer: @escaping @Sendable (ViewerAdmissionHandle) -> Void = { _ in },
    shutdownOperation: @escaping @Sendable () async -> Void = {}
  ) {
    self.runtimeLogicalID = runtimeLogicalID
    self.managerGeneration = managerGeneration
    self.onTransfer = onTransfer
    self.shutdownOperation = shutdownOperation
  }

  func setSnapshotHandler(_ handler: @escaping @Sendable ([ViewerSessionSnapshot]) -> Void) {
    handler([])
  }

  func disconnect(connectionID: UUID) {}
  func updatePolicy(connectionID: UUID, policy: ViewerRatePolicy) {}
  func controlTargets() -> [ViewerControlTarget] { [] }
  func send(
    _ prepared: ViewerPreparedControlEvent,
    to capabilities: [ViewerControlTargetCapability]
  ) throws -> [ViewerControlTargetResult] { [] }
  func setNickname(_ nickname: String?, route: ViewerLogicalRoute) -> Bool { false }

  func transfer(_ handle: ViewerAdmissionHandle) -> Bool {
    lock.lock()
    guard !shuttingDown else {
      lock.unlock()
      return false
    }
    handles.append(handle)
    lock.unlock()
    onTransfer(handle)
    return true
  }

  func beginShutdown() -> Task<Void, Never> {
    lock.lock()
    if let shutdownTask {
      lock.unlock()
      return shutdownTask
    }
    shuttingDown = true
    let handles = self.handles
    self.handles.removeAll()
    let shutdownOperation = self.shutdownOperation
    let task = Task {
      await shutdownOperation()
      for handle in handles { await handle.cancelAndWait() }
    }
    shutdownTask = task
    lock.unlock()
    return task
  }
}

private final class LockedSummaryBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: ViewerPendingAppSummary?

  func set(_ value: ViewerPendingAppSummary) {
    lock.lock()
    storage = value
    lock.unlock()
  }

  var value: ViewerPendingAppSummary? {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private final class FakeIdentityPersistence: ViewerIdentityPersistence, @unchecked Sendable {
  enum Operation: String, Hashable {
    case copyGenericPassword
    case addGenericPassword
    case deleteGenericPassword
    case createPrivateKey
    case copyPrivateKey
    case deletePrivateKey
    case addCertificate
    case copyCertificate
    case deleteCertificate
    case copyIdentity
  }

  private struct CertificateRecord {
    let certificate: SecCertificate
    let label: String
  }

  private let lock = NSLock()
  private var genericPasswords: [String: Data] = [:]
  private var privateKey: SecKey?
  private var certificates: [Data: CertificateRecord] = [:]
  private var nextReference = 1
  private var failures: [Operation: Int] = [:]
  private var calls: [Operation: Int] = [:]

  func failNext(_ operation: Operation) {
    lock.lock()
    failures[operation, default: 0] += 1
    lock.unlock()
  }

  func copyGenericPassword(account: String) throws -> Data {
    try begin(.copyGenericPassword)
    lock.lock()
    defer { lock.unlock() }
    guard let value = genericPasswords[account] else {
      throw ViewerIdentityPersistenceError.missing
    }
    return value
  }

  func addGenericPassword(account: String, value: Data) throws {
    try begin(.addGenericPassword)
    lock.lock()
    defer { lock.unlock() }
    guard genericPasswords[account] == nil else {
      throw ViewerIdentityPersistenceError.operation
    }
    genericPasswords[account] = value
  }

  func deleteGenericPassword(account: String, requirePresent: Bool) throws {
    try begin(.deleteGenericPassword)
    lock.lock()
    defer { lock.unlock() }
    let removed = genericPasswords.removeValue(forKey: account)
    if requirePresent, removed == nil { throw ViewerIdentityPersistenceError.missing }
  }

  func createPrivateKey(builder: ViewerCertificateBuilder) throws -> SecKey {
    try begin(.createPrivateKey)
    let key = try builder.createEphemeralPrivateKey()
    lock.lock()
    privateKey = key
    lock.unlock()
    return key
  }

  func copyPrivateKey() throws -> SecKey {
    try begin(.copyPrivateKey)
    lock.lock()
    defer { lock.unlock() }
    guard let privateKey else { throw ViewerIdentityPersistenceError.missing }
    return privateKey
  }

  func deletePrivateKey(requirePresent: Bool) throws {
    try begin(.deletePrivateKey)
    lock.lock()
    defer { lock.unlock() }
    if requirePresent, privateKey == nil { throw ViewerIdentityPersistenceError.missing }
    privateKey = nil
  }

  func privateKeyItemExists() throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return privateKey != nil
  }

  func addCertificate(_ certificate: SecCertificate, label: String) throws -> Data {
    try begin(.addCertificate)
    lock.lock()
    defer { lock.unlock() }
    let reference = Data("certificate-\(nextReference)".utf8)
    nextReference += 1
    certificates[reference] = CertificateRecord(certificate: certificate, label: label)
    return reference
  }

  func copyCertificate(persistentReference: Data) throws -> SecCertificate {
    try begin(.copyCertificate)
    lock.lock()
    defer { lock.unlock() }
    guard let record = certificates[persistentReference] else {
      throw ViewerIdentityPersistenceError.missing
    }
    return record.certificate
  }

  func deleteCertificate(persistentReference: Data, requirePresent: Bool) throws {
    try begin(.deleteCertificate)
    lock.lock()
    defer { lock.unlock() }
    let removed = certificates.removeValue(forKey: persistentReference)
    if requirePresent, removed == nil { throw ViewerIdentityPersistenceError.missing }
  }

  func copyIdentity(certificate: SecCertificate, privateKey: SecKey) throws -> SecIdentity {
    try begin(.copyIdentity)
    throw ViewerIdentityPersistenceError.invalid
  }

  func corruptTLSMetadata() {
    lock.lock()
    genericPasswords["tls-metadata"] = Data("invalid".utf8)
    lock.unlock()
  }

  func removePrivateKey() {
    lock.lock()
    privateKey = nil
    lock.unlock()
  }

  func replacePrivateKey(_ key: SecKey) {
    lock.lock()
    privateKey = key
    lock.unlock()
  }

  func addForeignCertificate(_ certificate: SecCertificate, label: String) throws -> Data {
    try addCertificate(certificate, label: label)
  }

  func pointMetadata(
    to reference: Data,
    certificate: SecCertificate,
    label: String,
    publicKey: SecKey
  ) throws {
    guard let publicBytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
      let serial = SecCertificateCopySerialNumberData(certificate, nil) as Data?
    else {
      throw ViewerTestError.exhausted
    }
    lock.lock()
    defer { lock.unlock() }
    guard let metadata = genericPasswords["tls-metadata"],
      var object = try JSONSerialization.jsonObject(with: metadata) as? [String: Any]
    else {
      throw ViewerTestError.exhausted
    }
    object["certificatePersistentReference"] = reference.base64EncodedString()
    object["certificateLabel"] = label
    object["serial"] = serial.base64EncodedString()
    object["publicKeyHash"] = Data(SHA256.hash(data: publicBytes)).base64EncodedString()
    object["certificateHash"] = Data(
      SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
    ).base64EncodedString()
    genericPasswords["tls-metadata"] = try JSONSerialization.data(withJSONObject: object)
  }

  var certificateCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return certificates.count
  }

  var hasPrivateKey: Bool {
    lock.lock()
    defer { lock.unlock() }
    return privateKey != nil
  }

  func hasGenericPassword(_ account: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return genericPasswords[account] != nil
  }

  func callCount(_ operation: Operation) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return calls[operation, default: 0]
  }

  private func begin(_ operation: Operation) throws {
    lock.lock()
    calls[operation, default: 0] += 1
    if failures[operation, default: 0] > 0 {
      failures[operation, default: 0] -= 1
      lock.unlock()
      throw ViewerIdentityPersistenceError.operation
    }
    lock.unlock()
  }
}

private func currentFoundationProcessPhysicalFootprintBytes() -> UInt64? {
  var information = task_vm_info_data_t()
  var count = mach_msg_type_number_t(
    MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
  )
  let result = withUnsafeMutablePointer(to: &information) { pointer in
    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
      task_info(
        mach_task_self_,
        task_flavor_t(TASK_VM_INFO),
        rebound,
        &count
      )
    }
  }
  return result == KERN_SUCCESS ? information.phys_footprint : nil
}
