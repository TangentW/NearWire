import Foundation
@_spi(NearWireInternal) import NearWireTransport
import Security
import XCTest

@testable import NearWire

final class SDKPublicConnectionFoundationTests: XCTestCase {
  func testEveryInternalConnectionErrorMapsToFixedSafePublicError() {
    let secret = "SECRET-PAIRING-ENDPOINT"
    for code in SDKSessionAdmissionError.Code.allCases {
      let mapped = SDKPublicConnectionErrorMapping.map(code)
      XCTAssertFalse(mapped.message.contains(secret), "Unexpected content for \(code)")
      XCTAssertFalse(mapped.description.contains(secret), "Unexpected description for \(code)")
      XCTAssertFalse(mapped.message.isEmpty)
    }

    XCTAssertEqual(
      SDKPublicConnectionErrorMapping.map(.anotherConnectionIsActive).code,
      .anotherConnectionIsActive
    )
    XCTAssertEqual(
      SDKPublicConnectionErrorMapping.map(.runtimeUnavailable).code,
      .connectionOwnershipUnavailable
    )
    XCTAssertEqual(
      SDKPublicConnectionErrorMapping.map(SDKInstallationIdentityError.unavailable).code,
      .connectionInternalFailure
    )
  }

  func testSDKVersionMatchesRepositoryVersion() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let versionFile = repository.appendingPathComponent("VERSION")
    guard FileManager.default.fileExists(atPath: versionFile.path) else {
      throw XCTSkip("The source-tree VERSION file is unavailable in this packaged test runtime.")
    }
    let version = try String(contentsOf: versionFile)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertEqual(SDKProductVersion.current, version)
    XCTAssertEqual(try SDKProductVersion.wireValue().rawValue, version)
  }

  func testBundleMetadataUsesOnlyValidStringsAndDocumentedFallbacks() {
    let metadata = SDKHostApplicationMetadata.resolve(
      SDKBundleMetadataInput(
        applicationIdentifier: "com.example.app",
        shortVersion: "bad\nversion",
        buildVersion: "42",
        displayName: "bad\u{0000}name",
        bundleName: "Example App"
      )
    )
    XCTAssertEqual(metadata.applicationIdentifier, "com.example.app")
    XCTAssertEqual(metadata.applicationVersion, "42")
    XCTAssertEqual(metadata.displayName, "Example App")

    let omitted = SDKHostApplicationMetadata.resolve(
      SDKBundleMetadataInput(
        applicationIdentifier: String(repeating: "a", count: 129),
        shortVersion: nil,
        buildVersion: "\t",
        displayName: nil,
        bundleName: "\n"
      )
    )
    XCTAssertNil(omitted.applicationIdentifier)
    XCTAssertNil(omitted.applicationVersion)
    XCTAssertNil(omitted.displayName)
  }

  func testLimitPlanKeepsNetworkMaximumIndependentFromBufferAccounting() throws {
    let smallBuffer = try NearWireBufferConfiguration(
      maximumEventCount: 10,
      maximumBytes: 64 * 1_024,
      maximumEventBytes: 4 * 1_024,
      defaultTTL: .seconds(60)
    )
    let largeBuffer = try NearWireBufferConfiguration(
      maximumEventCount: 10,
      maximumBytes: 16 * 1_024 * 1_024,
      maximumEventBytes: 16 * 1_024 * 1_024,
      defaultTTL: .seconds(60)
    )
    let small = try SDKPublicConnectionLimitPlan.make(
      configuration: NearWireConfiguration(buffer: smallBuffer)
    )
    let large = try SDKPublicConnectionLimitPlan.make(
      configuration: NearWireConfiguration(buffer: largeBuffer)
    )

    XCTAssertEqual(small.maximumEventRecordBytes, large.maximumEventRecordBytes)
    XCTAssertEqual(small.wireLimits.maximumEventBytes, large.wireLimits.maximumEventBytes)
    XCTAssertEqual(
      small.activeLimits.maximumOutboundAccountedBytesPerTurn,
      SDKActiveEventPumpLimits.default.maximumOutboundAccountedBytesPerTurn
    )
    XCTAssertEqual(
      large.activeLimits.maximumOutboundAccountedBytesPerTurn,
      largeBuffer.maximumEventBytes
    )
    XCTAssertGreaterThanOrEqual(
      small.transportLimits.maximumPendingSendBytes,
      small.maximumEncodedEventFrameBytes
        + 2 * small.wireLimits.frame.maximumEncodedFrameBytes(for: .control)
    )
  }

  func testLimitPlanUsesExactReviewedDownstreamCapacities() throws {
    let configuration = try NearWireConfiguration()
    let plan = try SDKPublicConnectionLimitPlan.make(configuration: configuration)
    let recordBytes = try WireEventRecord.maximumDeterministicEncodedByteCount()
    let frameBytes = try WireSessionCodec.maximumEncodedV1SingleEventFrameBytes(
      maximumEventBytes: recordBytes,
      frameLimits: plan.wireLimits.frame
    )
    let controlFrameBytes = plan.wireLimits.frame.maximumEncodedFrameBytes(for: .control)
    let requiredPendingBytes = frameBytes + 2 * controlFrameBytes

    XCTAssertEqual(plan.maximumEventRecordBytes, recordBytes)
    XCTAssertEqual(plan.wireLimits.maximumEventBytes, recordBytes)
    XCTAssertEqual(plan.maximumEncodedEventFrameBytes, frameBytes)
    XCTAssertEqual(
      plan.wireLimits.frame.maximumEventPayloadBytes,
      max(
        WireFrameLimits.default.maximumEventPayloadBytes,
        frameBytes - WireFrameLimits.encodedFrameOverheadBytes
      )
    )
    XCTAssertEqual(
      plan.transportLimits.maximumSingleSendBytes,
      max(
        SecureTransportLimits.default.maximumSingleSendBytes,
        frameBytes,
        controlFrameBytes
      )
    )
    XCTAssertEqual(
      plan.transportLimits.maximumPendingSendBytes,
      max(SecureTransportLimits.default.maximumPendingSendBytes, requiredPendingBytes)
    )
    XCTAssertEqual(
      plan.activeLimits.maximumIncomingEncodedBytes,
      max(SDKActiveEventPumpLimits.default.maximumIncomingEncodedBytes, recordBytes)
    )
    XCTAssertEqual(
      plan.activeLimits.maximumOutboundAccountedBytesPerTurn,
      max(
        SDKActiveEventPumpLimits.default.maximumOutboundAccountedBytesPerTurn,
        configuration.buffer.maximumEventBytes
      )
    )
    XCTAssertLessThanOrEqual(
      plan.transportLimits.maximumSingleSendBytes,
      SecureTransportLimits.hardMaximumSingleSendBytes
    )
    XCTAssertLessThanOrEqual(
      plan.transportLimits.maximumPendingSendBytes,
      SecureTransportLimits.hardMaximumPendingSendBytes
    )
    XCTAssertLessThanOrEqual(
      plan.activeLimits.maximumIncomingEncodedBytes,
      SDKActiveEventPumpLimits.hardMaximumIncomingBytes
    )
  }

  func testIdentityHitUsesExactReadDictionaryOnly() async throws {
    let value = "123e4567-e89b-42d3-a456-426614174000"
    let operations = SDKIdentityOperationsFixture(
      reads: [.data(Data(value.utf8))],
      add: .failed,
      random: nil
    )
    let result = try await SDKInstallationIdentityStore(operations: operations).load()
    XCTAssertEqual(result, value)
    let snapshot = operations.snapshot
    XCTAssertEqual(snapshot.reads, [SDKInstallationIdentityStore.readAttributes])
    XCTAssertTrue(snapshot.adds.isEmpty)
    XCTAssertEqual(snapshot.randomCounts, [])
    XCTAssertEqual(
      SDKInstallationIdentityStore.readAttributes[
        SDKInstallationIdentityStore.Key.authenticationUI],
      .authenticationUISkip
    )
  }

  func testIdentityMissingGeneratesV4AndAddsExactAttributes() async throws {
    let operations = SDKIdentityOperationsFixture(
      reads: [.missing],
      add: .added,
      random: Array(repeating: 0xFF, count: 16)
    )
    let result = try await SDKInstallationIdentityStore(operations: operations).load()
    XCTAssertEqual(result, "ffffffff-ffff-4fff-bfff-ffffffffffff")
    let snapshot = operations.snapshot
    XCTAssertEqual(snapshot.randomCounts, [16])
    XCTAssertEqual(snapshot.adds.count, 1)
    XCTAssertEqual(
      snapshot.adds[0],
      SDKInstallationIdentityStore.addAttributes(data: Data(result.utf8))
    )
  }

  func testLiveKeychainTranslationUsesOnlyReviewedSecurityConstants() {
    let live = SDKLiveInstallationIdentityOperations()
    let read = live.makeDictionary(SDKInstallationIdentityStore.readAttributes) as NSDictionary
    XCTAssertEqual(read.count, 7)
    assertCFEqual(read[kSecClass], kSecClassGenericPassword)
    XCTAssertEqual(read[kSecAttrService] as? String, SDKInstallationIdentityStore.service)
    XCTAssertEqual(read[kSecAttrAccount] as? String, SDKInstallationIdentityStore.account)
    assertCFEqual(read[kSecUseDataProtectionKeychain], kCFBooleanTrue)
    assertCFEqual(read[kSecReturnData], kCFBooleanTrue)
    assertCFEqual(read[kSecMatchLimit], kSecMatchLimitOne)
    assertCFEqual(read[kSecUseAuthenticationUI], kSecUseAuthenticationUISkip)

    let data = Data("123e4567-e89b-42d3-a456-426614174000".utf8)
    let add =
      live.makeDictionary(
        SDKInstallationIdentityStore.addAttributes(data: data)
      ) as NSDictionary
    XCTAssertEqual(add.count, 6)
    assertCFEqual(add[kSecClass], kSecClassGenericPassword)
    XCTAssertEqual(add[kSecAttrService] as? String, SDKInstallationIdentityStore.service)
    XCTAssertEqual(add[kSecAttrAccount] as? String, SDKInstallationIdentityStore.account)
    assertCFEqual(add[kSecUseDataProtectionKeychain], kCFBooleanTrue)
    assertCFEqual(add[kSecAttrAccessible], kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    XCTAssertEqual(add[kSecValueData] as? Data, data)
  }

  func testIdentityDuplicatePerformsExactlyOneBoundedReread() async throws {
    let winner = "123e4567-e89b-42d3-a456-426614174000"
    let operations = SDKIdentityOperationsFixture(
      reads: [.missing, .data(Data(winner.utf8))],
      add: .duplicate,
      random: Array(repeating: 0, count: 16)
    )
    let result = try await SDKInstallationIdentityStore(operations: operations).load()
    XCTAssertEqual(result, winner)
    XCTAssertEqual(operations.snapshot.reads.count, 2)
    XCTAssertEqual(operations.snapshot.adds.count, 1)
    XCTAssertEqual(operations.snapshot.randomCounts, [16])
  }

  func testIdentityFailureTranscriptsNeverRetryOrWriteAgain() async {
    let cases:
      [(
        name: String,
        reads: [SDKSecurityItemReadResult],
        add: SDKSecurityItemAddResult,
        random: [UInt8]?,
        expected: (reads: Int, random: Int, adds: Int)
      )] = [
        ("initial access failure", [.failed], .added, Array(repeating: 0, count: 16), (1, 0, 0)),
        (
          "initial unexpected value", [.unexpectedValue], .added,
          Array(repeating: 0, count: 16), (1, 0, 0)
        ),
        (
          "initial malformed data", [.data(Data("not-a-uuid".utf8))], .added,
          Array(repeating: 0, count: 16), (1, 0, 0)
        ),
        ("random failure", [.missing], .added, nil, (1, 1, 0)),
        ("random length failure", [.missing], .added, Array(repeating: 0, count: 15), (1, 1, 0)),
        ("ordinary add failure", [.missing], .failed, Array(repeating: 0, count: 16), (1, 1, 1)),
        (
          "protected duplicate is skipped", [.missing, .missing], .duplicate,
          Array(repeating: 0, count: 16), (2, 1, 1)
        ),
        (
          "duplicate unexpected value", [.missing, .unexpectedValue], .duplicate,
          Array(repeating: 0, count: 16), (2, 1, 1)
        ),
        (
          "duplicate access failure", [.missing, .failed], .duplicate,
          Array(repeating: 0, count: 16), (2, 1, 1)
        ),
        (
          "duplicate malformed value", [.missing, .data(Data("not-a-uuid".utf8))],
          .duplicate, Array(repeating: 0, count: 16), (2, 1, 1)
        ),
        (
          "duplicate noncanonical value",
          [.missing, .data(Data("123E4567-E89B-42D3-A456-426614174000".utf8))], .duplicate,
          Array(repeating: 0, count: 16), (2, 1, 1)
        ),
        (
          "duplicate wrong UUID version",
          [.missing, .data(Data("123e4567-e89b-12d3-a456-426614174000".utf8))], .duplicate,
          Array(repeating: 0, count: 16), (2, 1, 1)
        ),
      ]

    for testCase in cases {
      let operations = SDKIdentityOperationsFixture(
        reads: testCase.reads,
        add: testCase.add,
        random: testCase.random
      )
      do {
        _ = try await SDKInstallationIdentityStore(operations: operations).load()
        XCTFail("Expected identity failure for \(testCase.name)")
      } catch let error as SDKInstallationIdentityError {
        XCTAssertEqual(error, .unavailable)
      } catch {
        XCTFail("Unexpected error for \(testCase.name): \(error)")
      }
      let snapshot = operations.snapshot
      XCTAssertEqual(snapshot.reads.count, testCase.expected.reads, testCase.name)
      XCTAssertEqual(snapshot.randomCounts.count, testCase.expected.random, testCase.name)
      XCTAssertEqual(snapshot.adds.count, testCase.expected.adds, testCase.name)
      XCTAssertTrue(snapshot.reads.allSatisfy { $0 == SDKInstallationIdentityStore.readAttributes })
    }
  }
}

private func assertCFEqual(
  _ actual: Any?,
  _ expected: CFTypeRef,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  guard let actual else {
    XCTFail("Expected Security dictionary value.", file: file, line: line)
    return
  }
  XCTAssertTrue(CFEqual(actual as CFTypeRef, expected), file: file, line: line)
}

private final class SDKIdentityOperationsFixture: SDKInstallationIdentityOperations,
  @unchecked Sendable
{
  struct Snapshot {
    let reads: [[String: SDKSecurityAttributeValue]]
    let adds: [[String: SDKSecurityAttributeValue]]
    let randomCounts: [Int]
  }

  private let lock = NSLock()
  private var pendingReads: [SDKSecurityItemReadResult]
  private let addResult: SDKSecurityItemAddResult
  private let random: [UInt8]?
  private var recordedReads: [[String: SDKSecurityAttributeValue]] = []
  private var recordedAdds: [[String: SDKSecurityAttributeValue]] = []
  private var recordedRandomCounts: [Int] = []

  init(
    reads: [SDKSecurityItemReadResult],
    add: SDKSecurityItemAddResult,
    random: [UInt8]?
  ) {
    pendingReads = reads
    addResult = add
    self.random = random
  }

  var snapshot: Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return Snapshot(
      reads: recordedReads,
      adds: recordedAdds,
      randomCounts: recordedRandomCounts
    )
  }

  func read(attributes: [String: SDKSecurityAttributeValue]) -> SDKSecurityItemReadResult {
    lock.lock()
    defer { lock.unlock() }
    recordedReads.append(attributes)
    guard !pendingReads.isEmpty else { return .failed }
    return pendingReads.removeFirst()
  }

  func add(attributes: [String: SDKSecurityAttributeValue]) -> SDKSecurityItemAddResult {
    lock.lock()
    defer { lock.unlock() }
    recordedAdds.append(attributes)
    return addResult
  }

  func randomBytes(count: Int) -> [UInt8]? {
    lock.lock()
    defer { lock.unlock() }
    recordedRandomCounts.append(count)
    return random
  }
}
