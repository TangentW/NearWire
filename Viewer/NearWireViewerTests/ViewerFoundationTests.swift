import Combine
import CryptoKit
import LocalAuthentication
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireTransport
import Security
import SwiftUI
import XCTest

@testable import NearWireViewer

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
  func testApplicationModelStartsOnceAndStopsIdempotently() async throws {
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

    model.openWindow()
    model.openWindow()
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
    XCTAssertEqual(model.status, .failed(.localNetworkUnavailable))

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
    hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
    hostingView.layoutSubtreeIfNeeded()

    XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
    XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    XCTAssertEqual(model.status, .stopped)
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

  func testRunningApplicationHasOnlyFoundationNetworkEntitlement() throws {
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
        "com.apple.security.network.server" as CFString,
        nil
      ) as? Bool,
      true
    )
    for forbidden in [
      "com.apple.security.network.client",
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

  func testListenerGenerationCancellationDoesNotAffectOtherGeneration() throws {
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
    wait(for: [bothStarted], timeout: 1)

    manager.cancelGeneration(oldGeneration)
    wait(for: [oldCancelled], timeout: 1)
    XCTAssertEqual(manager.occupiedCount, 1)
    XCTAssertEqual(newIncoming.channel.cancelCount, 0)

    manager.stop()
    wait(for: [newCancelled], timeout: 1)
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
    let cleanupGate = AsyncTestGate()
    let resetCalled = expectation(description: "Reset called after cleanup")
    let resetCount = LockedTestCounter()
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
          resetCount.increment()
          resetCalled.fulfill()
        },
        resetAllIdentity: {},
        generatePairingCode: { try PairingCode("ABCDEF") },
        makeHandoffOwner: {
          FakeAdmissionHandoffOwner(shutdownOperation: { await cleanupGate.wait() })
        }
      )
    )
    model.openWindow()
    await waitForStatus(.listening(code: "ABCDEF", paused: false), in: model)
    XCTAssertEqual(model.status, .listening(code: "ABCDEF", paused: false))

    model.resetTLSIdentity()
    cleanupGate.waitUntilEntered()
    XCTAssertEqual(resetCount.value, 0)
    XCTAssertEqual(model.status, .stopping)
    cleanupGate.open()
    await fulfillment(of: [resetCalled], timeout: 1)
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
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func wait() async {
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

private final class FakeAdmissionHandoffOwner: ViewerAdmissionHandoffOwning, @unchecked Sendable {
  private let lock = NSLock()
  private let onTransfer: @Sendable (ViewerAdmissionHandle) -> Void
  private let shutdownOperation: @Sendable () async -> Void
  private var handles: [ViewerAdmissionHandle] = []
  private var shuttingDown = false
  private var shutdownTask: Task<Void, Never>?

  init(
    onTransfer: @escaping @Sendable (ViewerAdmissionHandle) -> Void = { _ in },
    shutdownOperation: @escaping @Sendable () async -> Void = {}
  ) {
    self.onTransfer = onTransfer
    self.shutdownOperation = shutdownOperation
  }

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
