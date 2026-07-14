@_spi(NearWireInternal) import NearWireCore
import Network
import Security
import XCTest

@_spi(NearWireInternal) @testable import NearWireTransport

final class SecureTransportTests: XCTestCase {
  func testDefaultLimitsAndFixedTLSPlan() throws {
    let limits = SecureTransportLimits.default
    XCTAssertEqual(limits.receiveChunkBytes, 64 * 1_024)
    XCTAssertEqual(limits.maximumPendingSendCount, 256)
    XCTAssertEqual(limits.maximumPendingSendBytes, 4 * 1_024 * 1_024)
    XCTAssertEqual(
      limits.maximumSingleSendBytes,
      WireFrameLimits.default.maximumEncodedFrameBytes(for: .event)
    )
    XCTAssertEqual(limits.connectionTimeoutSeconds, 10)

    let plan = SecureTLSPlan.v1
    XCTAssertTrue(plan.requiresTLS)
    XCTAssertTrue(plan.orderedTCP)
    XCTAssertEqual(plan.minimumTLSVersion, "1.3")
    XCTAssertEqual(plan.maximumTLSVersion, "1.3")
    XCTAssertEqual(plan.applicationProtocols, ["nearwire/1"])
    XCTAssertTrue(plan.includesPeerToPeer)
  }

  func testInvalidLimitsFailWithoutPartialConfiguration() throws {
    assertTransportError(.invalidConfiguration) {
      _ = try SecureTransportLimits(receiveChunkBytes: 0)
    }
    assertTransportError(.invalidConfiguration) {
      _ = try SecureTransportLimits(maximumPendingSendCount: 4_097)
    }
    assertTransportError(.invalidConfiguration) {
      _ = try SecureTransportLimits(
        maximumPendingSendBytes: 1_024,
        maximumSingleSendBytes: 2_048
      )
    }
    assertTransportError(.invalidConfiguration) {
      _ = try SecureTransportLimits(connectionTimeoutSeconds: 121)
    }
  }

  func testExactDefaultAndHardBoundFramesFitSingleSendLimits() throws {
    let defaultFrame = try WireFrameEncoder.encode(
      lane: .event,
      payload: Data(repeating: 1, count: WireFrameLimits.default.maximumEventPayloadBytes)
    )
    XCTAssertEqual(defaultFrame.count, SecureTransportLimits.default.maximumSingleSendBytes)

    XCTAssertEqual(
      SecureTransportLimits.hardMaximumSingleSendBytes,
      WireFrameLimits.hardMaximumPayloadBytes + WireFrameLimits.encodedFrameOverheadBytes
    )
    let transportLimits = try SecureTransportLimits(
      maximumPendingSendBytes: SecureTransportLimits.hardMaximumPendingSendBytes,
      maximumSingleSendBytes: SecureTransportLimits.hardMaximumSingleSendBytes
    )
    XCTAssertEqual(
      transportLimits.maximumSingleSendBytes,
      SecureTransportLimits.hardMaximumSingleSendBytes
    )
  }

  func testRoleParametersContainTLSOverTCPAndPeerToPeerRouting() throws {
    let appParameters = SecureNetworkParameters.appClient(
      verificationQueue: DispatchQueue(label: "nearwire.tests.verify")
    )
    let identity = try ViewerTransportIdentity(identity: makeViewerIdentity())
    let viewerParameters = SecureNetworkParameters.viewerServer(identity: identity)

    for parameters in [appParameters, viewerParameters] {
      XCTAssertTrue(parameters.includePeerToPeer)
      XCTAssertTrue(
        parameters.defaultProtocolStack.applicationProtocols.contains {
          $0 is NWProtocolTLS.Options
        }
      )
      let tcp = try XCTUnwrap(
        parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options
      )
      XCTAssertTrue(tcp.enableKeepalive)
      XCTAssertEqual(tcp.keepaliveIdle, SecureNetworkParameters.keepaliveIdleSeconds)
      XCTAssertEqual(tcp.keepaliveInterval, SecureNetworkParameters.keepaliveIntervalSeconds)
      XCTAssertEqual(tcp.keepaliveCount, SecureNetworkParameters.keepaliveProbeCount)
    }
  }

  func testTransportValuesAreSendable() {
    assertSendable(SecureTransportLimits.self)
    assertSendable(SecureTLSPlan.self)
    assertSendable(SecureTransportError.self)
    assertSendable(ViewerTransportIdentity.self)
  }

  func testViewerIdentityAdaptsValidIdentityAndFailsClosed() throws {
    let identity = try makeViewerIdentity()

    XCTAssertNoThrow(try ViewerTransportIdentity(identity: identity))

    var adaptationCount = 0
    assertTransportError(.identityAdaptationFailed) {
      _ = try ViewerTransportIdentity(identity: identity) { _ in
        adaptationCount += 1
        return nil
      }
    }
    XCTAssertEqual(adaptationCount, 1)
  }

  func testViewerListenerStartAndCancellationAreSingleShot() async throws {
    let identity = try ViewerTransportIdentity(identity: makeViewerIdentity())
    let listener = try SecureViewerTransport.makeListener(identity: identity)
    let cancelled = expectation(description: "listener cancelled once")
    cancelled.assertForOverFulfill = true
    let queue = DispatchQueue(label: "nearwire.tests.listener-lifecycle")

    try listener.start(queue: queue) { event in
      if case .cancelled = event { cancelled.fulfill() }
    }
    assertTransportError(.alreadyStarted) {
      try listener.start(queue: queue) { _ in }
    }
    listener.cancel()
    listener.cancel()
    await fulfillment(of: [cancelled], timeout: 1)
  }

  func testViewerAdvertisementMapsOnlyValidatedBonjourIdentity() throws {
    let viewerID = try EndpointID(rawValue: "viewer-installation")
    let discriminator = ViewerDiscoveryDiscriminator(viewerInstallationID: viewerID)
    let serviceIdentity = try XCTUnwrap(
      NearWireBonjourServiceIdentity(
        instanceName: "NearWire-ABCDEF",
        type: NearWireBonjour.serviceType,
        domain: NearWireBonjour.localDomain,
        viewerDiscriminator: discriminator
      )
    )
    let advertisement = SecureViewerServiceAdvertisement(identity: serviceIdentity)
    let service = advertisement.listenerService

    XCTAssertEqual(service.name, "NearWire-ABCDEF")
    XCTAssertEqual(service.type, "_nearwire._tcp")
    XCTAssertEqual(service.domain, "local.")
    XCTAssertEqual(
      NWTXTRecord(try XCTUnwrap(service.txtRecord)).dictionary,
      [NearWireBonjour.txtViewerIDKey: discriminator.rawValue]
    )
    XCTAssertTrue(
      advertisement.exactlyMatches(
        .service(
          name: "NearWire-ABCDEF",
          type: "_nearwire._tcp",
          domain: "local.",
          interface: nil
        )
      )
    )
    XCTAssertFalse(
      advertisement.exactlyMatches(
        .service(
          name: "NearWire-ABCDEF (2)",
          type: "_nearwire._tcp",
          domain: "local.",
          interface: nil
        )
      )
    )
  }

  func testViewerListenerMapsOnlyPermissionFailuresToLocalNetworkCategory() {
    XCTAssertTrue(SecureViewerListener.isLocalNetworkPermissionFailure(.dns(-65_570)))
    XCTAssertTrue(SecureViewerListener.isLocalNetworkPermissionFailure(.posix(.EACCES)))
    XCTAssertTrue(SecureViewerListener.isLocalNetworkPermissionFailure(.posix(.EPERM)))
    XCTAssertFalse(SecureViewerListener.isLocalNetworkPermissionFailure(.posix(.ECONNRESET)))
    XCTAssertEqual(
      SecureViewerListener.listenerFailure(for: .dns(-65_570)).code,
      .localNetworkUnavailable
    )
    XCTAssertEqual(
      SecureViewerListener.listenerFailure(for: .posix(.ECONNRESET)).code,
      .driverFailure
    )
  }

  func testViewerAdmissionClaimIsAtomicWithClose() async throws {
    let gate = SecureViewerAdmissionGate()
    let claimEntered = expectation(description: "claim entered")
    let closeAtLockBoundary = expectation(description: "close at lock boundary")
    let claimFinished = expectation(description: "claim finished")
    let closeFinished = expectation(description: "close finished")
    let releaseClaim = DispatchSemaphore(value: 0)
    let allowCloseLockAttempt = DispatchSemaphore(value: 0)
    let recorder = AdmissionRaceRecorder()

    DispatchQueue.global().async {
      let admitted =
        gate.withOpenClaim {
          recorder.append("claim-entered")
          claimEntered.fulfill()
          releaseClaim.wait()
          recorder.append("claim-committed")
          return true
        } ?? false
      recorder.setClaimResult(admitted)
      recorder.append("claim-returned")
      claimFinished.fulfill()
    }
    await fulfillment(of: [claimEntered], timeout: 1)

    DispatchQueue.global().async {
      gate.close {
        recorder.append("close-at-lock-boundary")
        closeAtLockBoundary.fulfill()
        allowCloseLockAttempt.wait()
      }
      recorder.append("close-returned")
      closeFinished.fulfill()
    }
    await fulfillment(of: [closeAtLockBoundary], timeout: 1)
    allowCloseLockAttempt.signal()
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertFalse(recorder.events.contains("close-returned"))
    releaseClaim.signal()
    await fulfillment(of: [claimFinished, closeFinished], timeout: 1)

    XCTAssertEqual(recorder.claimResult, true)
    let events = recorder.events
    XCTAssertLessThan(
      try XCTUnwrap(events.firstIndex(of: "claim-committed")),
      try XCTUnwrap(events.firstIndex(of: "close-returned"))
    )
    XCTAssertNil(gate.withOpenClaim { true })
  }

  func testViewerListenerSerializesCallbacksOnConcurrentTarget() async throws {
    let certificate = try makeViewerCertificate()
    guard try systemTrustEvaluationIsAvailable(for: certificate) else {
      throw XCTSkip("Network and trust services are unavailable in the restricted test sandbox.")
    }
    let identity = try ViewerTransportIdentity(identity: makeViewerIdentity())
    let listener = try SecureViewerTransport.makeListener(identity: identity)
    let readyEntered = expectation(description: "ready callback entered")
    let cancelSubmitted = expectation(description: "cancel submitted")
    let cancelled = expectation(description: "cancelled callback")
    let releaseReady = DispatchSemaphore(value: 0)
    let recorder = ListenerCallbackRecorder()
    let concurrentTarget = DispatchQueue(
      label: "nearwire.tests.listener-concurrent-target",
      attributes: .concurrent
    )

    try listener.start(queue: concurrentTarget) { event in
      switch event {
      case .ready:
        recorder.beginCallback()
        readyEntered.fulfill()
        releaseReady.wait()
        recorder.endCallback()
      case .cancelled:
        recorder.beginCallback()
        recorder.endCallback()
        cancelled.fulfill()
      default:
        break
      }
    }
    await fulfillment(of: [readyEntered], timeout: 2)

    DispatchQueue.global().async {
      listener.cancel()
      cancelSubmitted.fulfill()
    }
    await fulfillment(of: [cancelSubmitted], timeout: 1)
    releaseReady.signal()
    await fulfillment(of: [cancelled], timeout: 1)

    XCTAssertFalse(recorder.observedOverlap)
  }

  func testConnectionLocalTrustAndFingerprint() throws {
    let certificate = try makeViewerCertificate()

    XCTAssertEqual(
      ConnectionLocalViewerTrust.fingerprintSHA256(certificate),
      "8546454f5c8cad81de6c7a9af963bc2995cc215ef7224bd3a1c4e1b82da01dae"
    )
    let invalidTrust = try makeTrust(for: certificate)
    XCTAssertEqual(
      SecTrustSetVerifyDate(
        invalidTrust,
        Date(timeIntervalSince1970: 0) as CFDate
      ),
      errSecSuccess
    )
    XCTAssertFalse(ConnectionLocalViewerTrust.evaluate(invalidTrust))

    guard try systemTrustEvaluationIsAvailable(for: certificate) else {
      throw XCTSkip("Security trust evaluation is unavailable in the restricted test sandbox.")
    }
    XCTAssertTrue(
      ConnectionLocalViewerTrust.evaluate(try makeTrust(for: certificate))
    )
  }

  func testProductionAppAndViewerCompleteTLS13ALPNHandshake() async throws {
    let certificate = try makeViewerCertificate()
    guard try systemTrustEvaluationIsAvailable(for: certificate) else {
      throw XCTSkip("Security trust evaluation is unavailable in the restricted test sandbox.")
    }
    let identity = try ViewerTransportIdentity(identity: makeViewerIdentity())
    let listener = try SecureViewerTransport.makeListener(identity: identity)
    let queue = DispatchQueue(label: "nearwire.tests.tls-handshake")
    let verificationQueue = DispatchQueue(label: "nearwire.tests.tls-verification")
    let listenerReady = expectation(description: "listener ready")
    let appReady = expectation(description: "app TLS ready")
    let viewerReady = expectation(description: "viewer TLS ready")
    let recorder = TransportHandshakeRecorder()

    try listener.start(queue: queue) { event in
      switch event {
      case .ready(let port):
        recorder.setPort(port)
        listenerReady.fulfill()
      case .incoming(let incoming):
        do {
          let channel = try incoming.makeChannel(queue: queue) { event in
            switch event {
            case .stateChanged(.ready): viewerReady.fulfill()
            case .terminated(let error): recorder.recordFailure(error.code)
            default: break
            }
          }
          recorder.setViewerChannel(channel)
          do {
            _ = try incoming.makeChannel(queue: queue) { _ in }
            recorder.recordFailure(nil)
          } catch let error as SecureTransportError {
            recorder.setDuplicateClaimCode(error.code)
          } catch {
            recorder.recordFailure(nil)
          }
          Task {
            do {
              try await channel.start()
            } catch {
              recorder.recordFailure((error as? SecureTransportError)?.code)
            }
          }
        } catch {
          recorder.recordFailure((error as? SecureTransportError)?.code)
        }
      case .failed(let error):
        recorder.recordFailure(error.code)
      case .serviceRegistered, .serviceRemoved:
        break
      case .cancelled:
        break
      }
    }

    await fulfillment(of: [listenerReady], timeout: 2)
    let rawPort = try XCTUnwrap(recorder.port)
    let port = try XCTUnwrap(NWEndpoint.Port(rawValue: rawPort))
    let appChannel = SecureAppTransport.makeChannel(
      endpoint: .hostPort(host: "127.0.0.1", port: port),
      connectionQueue: queue,
      verificationQueue: verificationQueue
    ) { event in
      switch event {
      case .stateChanged(.ready): appReady.fulfill()
      case .terminated(let error): recorder.recordFailure(error.code)
      default: break
      }
    }
    try await appChannel.start()
    await fulfillment(of: [appReady, viewerReady], timeout: 3)

    XCTAssertTrue(recorder.failures.isEmpty)
    XCTAssertEqual(recorder.duplicateClaimCode, .invalidState)
    await appChannel.cancel()
    if let viewerChannel = recorder.viewerChannel {
      await viewerChannel.cancel()
    }
    listener.cancel()
  }

  func testViewerRejectsTLS12Downgrade() async throws {
    let certificate = try makeViewerCertificate()
    guard try systemTrustEvaluationIsAvailable(for: certificate) else {
      throw XCTSkip("Security trust evaluation is unavailable in the restricted test sandbox.")
    }
    let identity = try ViewerTransportIdentity(identity: makeViewerIdentity())
    let listener = try SecureViewerTransport.makeListener(identity: identity)
    let queue = DispatchQueue(label: "nearwire.tests.tls12-rejection")
    let listenerReady = expectation(description: "listener ready")
    let rawTerminal = expectation(description: "TLS 1.2 client terminal")
    let channelRejected = expectation(description: "TLS 1.2 channel rejected")
    let recorder = RejectedHandshakeRecorder()

    try listener.start(queue: queue) { event in
      switch event {
      case .ready(let port):
        recorder.setPort(port)
        listenerReady.fulfill()
      case .incoming(let incoming):
        recorder.markIncoming()
        do {
          let channel = try incoming.makeChannel(queue: queue) { channelEvent in
            switch channelEvent {
            case .stateChanged(.ready):
              recorder.markChannelReady()
            case .terminated(let error):
              if recorder.recordChannelRejection(error.code) { channelRejected.fulfill() }
            default:
              break
            }
          }
          recorder.setViewerChannel(channel)
          Task { try? await channel.start() }
        } catch let error as SecureTransportError {
          if recorder.recordChannelRejection(error.code) { channelRejected.fulfill() }
        } catch {
          if recorder.recordChannelRejection(nil) { channelRejected.fulfill() }
        }
      case .failed(let error):
        recorder.setListenerFailure(error.code)
        if recorder.recordChannelRejection(error.code) { channelRejected.fulfill() }
      case .serviceRegistered, .serviceRemoved:
        break
      case .cancelled:
        break
      }
    }
    await fulfillment(of: [listenerReady], timeout: 2)

    let rawClient = try makeRawTestConnection(
      port: XCTUnwrap(recorder.port),
      version: .TLSv12,
      applicationProtocol: SecureNetworkParameters.applicationProtocol,
      queue: queue
    )
    rawClient.stateUpdateHandler = { state in
      switch state {
      case .ready:
        recorder.markRawReady()
      case .failed, .cancelled:
        if recorder.recordRawRejection() { rawTerminal.fulfill() }
      default:
        break
      }
    }
    rawClient.start(queue: queue)
    await fulfillment(of: [channelRejected], timeout: 3)

    XCTAssertFalse(recorder.rawReady)
    XCTAssertFalse(recorder.channelReady)
    XCTAssertEqual(recorder.channelTerminal, .driverFailure)
    rawClient.cancel()
    await fulfillment(of: [rawTerminal], timeout: 1)
    XCTAssertFalse(recorder.rawReady)
    XCTAssertTrue(recorder.rawFailed)
    if let viewerChannel = recorder.viewerChannel { await viewerChannel.cancel() }
    listener.cancel()
  }

  func testViewerRejectsMismatchedALPNBeforeChannelReady() async throws {
    let certificate = try makeViewerCertificate()
    guard try systemTrustEvaluationIsAvailable(for: certificate) else {
      throw XCTSkip("Security trust evaluation is unavailable in the restricted test sandbox.")
    }
    let identity = try ViewerTransportIdentity(identity: makeViewerIdentity())
    let listener = try SecureViewerTransport.makeListener(identity: identity)
    let queue = DispatchQueue(label: "nearwire.tests.alpn-rejection")
    let listenerReady = expectation(description: "listener ready")
    let channelRejected = expectation(description: "ALPN channel rejected")
    let recorder = RejectedHandshakeRecorder()

    try listener.start(queue: queue) { event in
      switch event {
      case .ready(let port):
        recorder.setPort(port)
        listenerReady.fulfill()
      case .incoming(let incoming):
        recorder.markIncoming()
        do {
          let channel = try incoming.makeChannel(queue: queue) { channelEvent in
            switch channelEvent {
            case .stateChanged(.ready):
              recorder.markChannelReady()
            case .terminated(let error):
              if recorder.recordChannelRejection(error.code) { channelRejected.fulfill() }
            default:
              break
            }
          }
          recorder.setViewerChannel(channel)
          Task { try? await channel.start() }
        } catch let error as SecureTransportError {
          if recorder.recordChannelRejection(error.code) { channelRejected.fulfill() }
        } catch {
          if recorder.recordChannelRejection(nil) { channelRejected.fulfill() }
        }
      case .failed(let error):
        recorder.setListenerFailure(error.code)
        if recorder.recordChannelRejection(error.code) { channelRejected.fulfill() }
      case .serviceRegistered, .serviceRemoved:
        break
      case .cancelled:
        break
      }
    }
    await fulfillment(of: [listenerReady], timeout: 2)

    let rawClient = try makeRawTestConnection(
      port: XCTUnwrap(recorder.port),
      version: .TLSv13,
      applicationProtocol: "wrong/1",
      queue: queue
    )
    rawClient.stateUpdateHandler = { state in
      switch state {
      case .ready:
        recorder.markRawReady()
      case .failed, .cancelled:
        _ = recorder.recordRawRejection()
      default:
        break
      }
    }
    rawClient.start(queue: queue)
    await fulfillment(of: [channelRejected], timeout: 3)

    XCTAssertFalse(recorder.channelReady)
    XCTAssertEqual(recorder.channelTerminal, .driverFailure)
    rawClient.cancel()
    if let viewerChannel = recorder.viewerChannel { await viewerChannel.cancel() }
    listener.cancel()
  }

  func testTrustSecuritySeamFailsClosedAndCompletesExactlyOnce() throws {
    let certificate = try makeViewerCertificate()
    let trust = try makeTrust(for: certificate)
    var policyCalls = 0
    var anchorCalls = 0
    var anchorOnlyCalls = 0
    var evaluationCalls = 0
    let acceptingSecurity = ConnectionLocalTrustSecurity(
      certificateChain: { _ in [certificate] },
      setBasicX509Policy: { _ in
        policyCalls += 1
        return errSecSuccess
      },
      setAnchorCertificates: { _, anchors in
        anchorCalls += 1
        XCTAssertEqual(CFArrayGetCount(anchors), 1)
        return errSecSuccess
      },
      setAnchorCertificatesOnly: { _, anchorOnly in
        anchorOnlyCalls += 1
        XCTAssertTrue(anchorOnly)
        return errSecSuccess
      },
      evaluate: { _ in
        evaluationCalls += 1
        return true
      }
    )
    var completionResults: [Bool] = []

    ConnectionLocalViewerTrust.completeVerification(
      trust,
      security: acceptingSecurity
    ) { result in
      completionResults.append(result)
    }

    XCTAssertEqual(completionResults, [true])
    XCTAssertEqual(policyCalls, 1)
    XCTAssertEqual(anchorCalls, 1)
    XCTAssertEqual(anchorOnlyCalls, 1)
    XCTAssertEqual(evaluationCalls, 1)

    let missingLeafSecurity = ConnectionLocalTrustSecurity(
      certificateChain: { _ in nil },
      setBasicX509Policy: { _ in
        XCTFail("Policy must not run without a leaf.")
        return errSecSuccess
      },
      setAnchorCertificates: { _, _ in errSecSuccess },
      setAnchorCertificatesOnly: { _, _ in errSecSuccess },
      evaluate: { _ in true }
    )
    XCTAssertFalse(
      ConnectionLocalViewerTrust.evaluate(trust, security: missingLeafSecurity)
    )

    let malformedPolicySecurity = ConnectionLocalTrustSecurity(
      certificateChain: { _ in [certificate] },
      setBasicX509Policy: { _ in errSecParam },
      setAnchorCertificates: { _, _ in
        XCTFail("Anchors must not run after policy failure.")
        return errSecSuccess
      },
      setAnchorCertificatesOnly: { _, _ in errSecSuccess },
      evaluate: { _ in true }
    )
    XCTAssertFalse(
      ConnectionLocalViewerTrust.evaluate(trust, security: malformedPolicySecurity)
    )

    let rejectedEvaluationSecurity = ConnectionLocalTrustSecurity(
      certificateChain: { _ in [certificate] },
      setBasicX509Policy: { _ in errSecSuccess },
      setAnchorCertificates: { _, _ in errSecSuccess },
      setAnchorCertificatesOnly: { _, _ in errSecSuccess },
      evaluate: { _ in false }
    )
    XCTAssertFalse(
      ConnectionLocalViewerTrust.evaluate(trust, security: rejectedEvaluationSecurity)
    )
  }

  private func assertTransportError(
    _ code: SecureTransportError.Code,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () throws -> Void
  ) {
    XCTAssertThrowsError(try operation(), file: file, line: line) { error in
      XCTAssertEqual((error as? SecureTransportError)?.code, code, file: file, line: line)
    }
  }

  private func assertSendable<Value: Sendable>(_ type: Value.Type) {}

  private func makeViewerCertificate() throws -> SecCertificate {
    let certificateData = try XCTUnwrap(Data(base64Encoded: Self.selfSignedCertificateBase64))
    return try XCTUnwrap(SecCertificateCreateWithData(nil, certificateData as CFData))
  }

  private func makeTrust(for certificate: SecCertificate) throws -> SecTrust {
    var trust: SecTrust?
    XCTAssertEqual(
      SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust),
      errSecSuccess
    )
    return try XCTUnwrap(trust)
  }

  private func systemTrustEvaluationIsAvailable(
    for certificate: SecCertificate
  ) throws -> Bool {
    let trust = try makeTrust(for: certificate)
    XCTAssertEqual(SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()), errSecSuccess)
    XCTAssertEqual(
      SecTrustSetAnchorCertificates(trust, [certificate] as CFArray),
      errSecSuccess
    )
    XCTAssertEqual(SecTrustSetAnchorCertificatesOnly(trust, true), errSecSuccess)
    var error: CFError?
    return SecTrustEvaluateWithError(trust, &error)
  }

  private func makeRawTestConnection(
    port: UInt16,
    version: tls_protocol_version_t,
    applicationProtocol: String,
    queue: DispatchQueue
  ) throws -> NWConnection {
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, version)
    sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, version)
    sec_protocol_options_add_tls_application_protocol(
      tls.securityProtocolOptions,
      applicationProtocol
    )
    sec_protocol_options_set_verify_block(
      tls.securityProtocolOptions,
      { _, _, completion in completion(true) },
      queue
    )
    let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    let endpointPort = try XCTUnwrap(NWEndpoint.Port(rawValue: port))
    return NWConnection(
      to: .hostPort(host: "127.0.0.1", port: endpointPort),
      using: parameters
    )
  }

  private func makeViewerIdentity() throws -> SecIdentity {
    let archive = try XCTUnwrap(Data(base64Encoded: Self.viewerIdentityPKCS12Base64))
    var importedItems: CFArray?
    var options: [String: Any] = [
      kSecImportExportPassphrase as String: "nearwire-test"
    ]
    if #available(macOS 15.0, iOS 18.0, *) {
      options[kSecImportToMemoryOnly as String] = true
    }
    let status = SecPKCS12Import(
      archive as CFData,
      options as CFDictionary,
      &importedItems
    )
    XCTAssertEqual(status, errSecSuccess)
    let items = try XCTUnwrap(importedItems as? [[String: Any]])
    let firstItem = try XCTUnwrap(items.first)
    return try XCTUnwrap(firstItem[kSecImportItemIdentity as String] as! SecIdentity?)
  }

  private static let selfSignedCertificateBase64 =
    "MIIDITCCAgmgAwIBAgIUTuSUarGKYsvK66/2fHhBpPuMKeUwDQYJKoZIhvcNAQELBQAwHzEdMBsGA1UEAwwUTmVhcldpcmUtVGVzdC1WaWV3ZXIwIBcNMjYwNzExMDAzMDU1WhgPMjEyNjA2MTcwMDMwNTVaMB8xHTAbBgNVBAMMFE5lYXJXaXJlLVRlc3QtVmlld2VyMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAvIWicPt26hRUB0/LFD4xzH+NGXWn6igYU0TN6L9HKUrCEg3J3qn473uyvJlJPyQnONGRdqsEGEyg2kSvYT37781zdMNs8Fa3dy/mSAiFQ+GEBjXj113VPKyJcjFuqZjJL3EKXBwSq9HeyPrQQWvugE0mcXSzS7Nukbpq3idpSeC1Mrk48TdWkm64ye3+7q/+vK2uAuYpaxciw8f5G1yr1Pi+Ye9PQju8dU3Rp9l8XAc7ZnN8WFHtQT8AQ2CpCieO+3H7zw28/jAG0RAKvWvAs++1f1E2aFywCIsAMu13ZFojCgiwNIjnmDmOX08AJGSRqVPkLJ+gDY7XNAyMyEFqGwIDAQABo1MwUTAdBgNVHQ4EFgQUXe//nCqcM2XIzgLT37wyu4N3w9AwHwYDVR0jBBgwFoAUXe//nCqcM2XIzgLT37wyu4N3w9AwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAkyOn097ojEjmkT2cSwpA1YrceSJMPS1o5nRY5TKmM4+xboUlvlhzTTujBeNv+VxT/Bid5x8nWK156PxHMa1fOnihgAbKNaRas4heXvtwl17M+yNueuWRrcbt0bSa8iQnCPJtDIu+ossb8OiL2s7KT0JT0TdnEx2CpmB/jL+4+JopNx2OrJ58SsthOjfAByWPBY0TNtDstl2S0Ax1GRCPpv9XItfZDNUW80og7Wme3GzfkKxAL54+pOA3D+7m1lJ7CMn5t/nHFNeaXtInXAH75bEAoSVpwYex5ovl0MT6Aaeb4bgslOSPtXwbVyf7vqere875orXa3CNmD4ZuIg2+1g=="

  // Test-only identity. Its private key is intentionally non-production and never leaves this process.
  private static let viewerIdentityPKCS12Base64 =
    "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"
}

private final class TransportHandshakeRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var _port: UInt16?
  private var _viewerChannel: SecureByteChannel?
  private var _failures: [SecureTransportError.Code?] = []
  private var _duplicateClaimCode: SecureTransportError.Code?

  func setPort(_ port: UInt16) {
    lock.lock()
    _port = port
    lock.unlock()
  }

  func setViewerChannel(_ channel: SecureByteChannel) {
    lock.lock()
    _viewerChannel = channel
    lock.unlock()
  }

  func recordFailure(_ code: SecureTransportError.Code?) {
    lock.lock()
    _failures.append(code)
    lock.unlock()
  }

  func setDuplicateClaimCode(_ code: SecureTransportError.Code) {
    lock.lock()
    _duplicateClaimCode = code
    lock.unlock()
  }

  var port: UInt16? {
    lock.lock()
    defer { lock.unlock() }
    return _port
  }

  var viewerChannel: SecureByteChannel? {
    lock.lock()
    defer { lock.unlock() }
    return _viewerChannel
  }

  var failures: [SecureTransportError.Code?] {
    lock.lock()
    defer { lock.unlock() }
    return _failures
  }

  var duplicateClaimCode: SecureTransportError.Code? {
    lock.lock()
    defer { lock.unlock() }
    return _duplicateClaimCode
  }
}

private final class RejectedHandshakeRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var _port: UInt16?
  private var _incoming = false
  private var _rawReady = false
  private var _rawFailed = false
  private var _channelReady = false
  private var _channelTerminal: SecureTransportError.Code?
  private var _listenerFailure: SecureTransportError.Code?
  private var _viewerChannel: SecureByteChannel?
  private var rawRejectionRecorded = false
  private var channelRejectionRecorded = false

  func setPort(_ port: UInt16) {
    lock.lock()
    _port = port
    lock.unlock()
  }

  func markIncoming() {
    lock.lock()
    _incoming = true
    lock.unlock()
  }

  func markRawReady() {
    lock.lock()
    _rawReady = true
    lock.unlock()
  }

  func recordRawRejection() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    _rawFailed = true
    guard !rawRejectionRecorded else { return false }
    rawRejectionRecorded = true
    return true
  }

  func markChannelReady() {
    lock.lock()
    _channelReady = true
    lock.unlock()
  }

  func recordChannelRejection(_ code: SecureTransportError.Code?) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    _channelTerminal = code
    guard !channelRejectionRecorded else { return false }
    channelRejectionRecorded = true
    return true
  }

  func setListenerFailure(_ code: SecureTransportError.Code) {
    lock.lock()
    _listenerFailure = code
    lock.unlock()
  }

  func setViewerChannel(_ channel: SecureByteChannel) {
    lock.lock()
    _viewerChannel = channel
    lock.unlock()
  }

  var port: UInt16? { read(\._port) }
  var incoming: Bool { read(\._incoming) }
  var rawReady: Bool { read(\._rawReady) }
  var rawFailed: Bool { read(\._rawFailed) }
  var channelReady: Bool { read(\._channelReady) }
  var channelTerminal: SecureTransportError.Code? { read(\._channelTerminal) }
  var listenerFailure: SecureTransportError.Code? { read(\._listenerFailure) }
  var viewerChannel: SecureByteChannel? { read(\._viewerChannel) }

  private func read<Value>(_ keyPath: KeyPath<RejectedHandshakeRecorder, Value>) -> Value {
    lock.lock()
    defer { lock.unlock() }
    return self[keyPath: keyPath]
  }
}

private final class AdmissionRaceRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var _events: [String] = []
  private var _claimResult: Bool?

  func append(_ event: String) {
    lock.lock()
    _events.append(event)
    lock.unlock()
  }

  func setClaimResult(_ result: Bool) {
    lock.lock()
    _claimResult = result
    lock.unlock()
  }

  var events: [String] {
    lock.lock()
    defer { lock.unlock() }
    return _events
  }

  var claimResult: Bool? {
    lock.lock()
    defer { lock.unlock() }
    return _claimResult
  }
}

private final class ListenerCallbackRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var callbackActive = false
  private var _observedOverlap = false

  func beginCallback() {
    lock.lock()
    if callbackActive { _observedOverlap = true }
    callbackActive = true
    lock.unlock()
  }

  func endCallback() {
    lock.lock()
    callbackActive = false
    lock.unlock()
  }

  var observedOverlap: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _observedOverlap
  }
}
