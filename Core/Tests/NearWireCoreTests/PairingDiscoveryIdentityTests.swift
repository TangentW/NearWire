import Foundation
import XCTest

@_spi(NearWireInternal) @testable import NearWireCore

final class PairingDiscoveryIdentityTests: XCTestCase {
  func testPairingCodeNormalizesOnlyDocumentedASCIISeparators() throws {
    let code = try PairingCode(" \t7k-\r\n3m ")
    XCTAssertEqual(code.canonicalValue, "7K3M")
    XCTAssertEqual(NearWireBonjour.instanceName(for: code), "NearWire-7K3M")

    for invalid in [
      "0K3M", "OK3M", "1K3M", "IK3M", "LK3M", "７K3M", "7K3\u{00A0}M",
      "7K3_M", "7K3", "7K3MZ", "7K\0 3M", "7K\u{001B}3M",
      "7K\u{007F}3M", "7K\u{202E}3M", "7K\u{2066}3M",
    ] {
      XCTAssertThrowsError(try PairingCode(invalid)) { error in
        XCTAssertEqual(error as? PairingCodeError, PairingCodeError())
        XCTAssertFalse(String(describing: error).contains(invalid))
      }
    }

    for separator in [9, 10, 11, 12, 13, 32, 45] {
      let scalar = UnicodeScalar(separator)!
      XCTAssertEqual(try PairingCode("7K\(scalar)3M").canonicalValue, "7K3M")
    }
  }

  func testEveryAlphabetByteAndCaseAreAccepted() throws {
    for byte in "ABCDEFGHJKMNPQRSTUVWXYZ23456789".utf8 {
      let scalar = String(UnicodeScalar(byte))
      let raw = String(repeating: scalar.lowercased(), count: PairingCode.canonicalLength)
      XCTAssertEqual(
        try PairingCode(raw).canonicalValue,
        String(repeating: scalar, count: PairingCode.canonicalLength)
      )
    }
  }

  func testRawInputWorkBound() throws {
    XCTAssertEqual(
      try PairingCode(
        String(
          repeating: "-",
          count: PairingCode.maximumRawUTF8Length - PairingCode.canonicalLength
        ) + "7K3M"
      ).canonicalValue,
      "7K3M"
    )
    for input in [
      String(repeating: "-", count: 65),
      String(
        repeating: " ",
        count: PairingCode.maximumRawUTF8Length - PairingCode.canonicalLength + 1
      ) + "7K3M",
    ] {
      XCTAssertThrowsError(try PairingCode(input))
    }
  }

  func testSensitiveDescriptionsAreRedacted() throws {
    let code = try PairingCode("7K3M")
    let discriminator = ViewerDiscoveryDiscriminator(
      viewerInstallationID: try EndpointID(rawValue: "viewer-installation")
    )
    let identity = NearWireBonjourServiceIdentity(
      instanceName: NearWireBonjour.instanceName(for: code),
      type: NearWireBonjour.serviceType,
      domain: NearWireBonjour.localDomain,
      viewerDiscriminator: discriminator
    )!

    for rendered in [
      code.description, code.debugDescription, String(describing: code), String(reflecting: code),
      discriminator.description, discriminator.debugDescription, String(describing: discriminator),
      String(reflecting: discriminator), identity.description, identity.debugDescription,
      String(describing: identity), String(reflecting: identity),
    ] {
      XCTAssertFalse(rendered.contains("7K3M"))
      XCTAssertFalse(rendered.contains("b3a97f874aad08bf"))
    }
  }

  func testDiscriminatorGoldenVectorsAndParsing() throws {
    let stableID = try EndpointID(rawValue: "viewer-installation")
    let firstStableValue = ViewerDiscoveryDiscriminator(viewerInstallationID: stableID)
    let secondStableValue = ViewerDiscoveryDiscriminator(viewerInstallationID: stableID)
    XCTAssertEqual(firstStableValue, secondStableValue)
    XCTAssertEqual(firstStableValue.rawValue, "b3a97f874aad08bf")
    XCTAssertEqual(
      ViewerDiscoveryDiscriminator(
        viewerInstallationID: try EndpointID(
          rawValue: "00000000-0000-0000-0000-000000000001"
        )
      ).rawValue,
      "7ac1b8d7010bb6cd"
    )
    XCTAssertNotEqual(
      ViewerDiscoveryDiscriminator(viewerInstallationID: try EndpointID(rawValue: "Viewer")),
      ViewerDiscoveryDiscriminator(viewerInstallationID: try EndpointID(rawValue: "viewer"))
    )
    XCTAssertEqual(
      ViewerDiscoveryDiscriminator(rawValue: "b3a97f874aad08bf")?.rawValue,
      "b3a97f874aad08bf"
    )
    for invalid in ["", "B3A97F874AAD08BF", "b3a97f874aad08bg", "b3a97f874aad08b"] {
      XCTAssertNil(ViewerDiscoveryDiscriminator(rawValue: invalid))
    }
    XCTAssertNil(
      ViewerDiscoveryDiscriminator(rawValue: String(repeating: "a", count: 1_000_000))
    )
  }

  func testServiceIdentityCanonicalizesTypeAndDomainButNotInstance() throws {
    let discriminator = ViewerDiscoveryDiscriminator(rawValue: "b3a97f874aad08bf")!
    let identity = NearWireBonjourServiceIdentity(
      instanceName: "NearWire-7K3M",
      type: "_NEARWIRE._TCP",
      domain: "LOCAL",
      viewerDiscriminator: discriminator
    )
    XCTAssertEqual(identity?.type, "_nearwire._tcp")
    XCTAssertEqual(identity?.domain, "local.")
    XCTAssertEqual(identity?.instanceName, "NearWire-7K3M")

    for hostileName in [
      "NearWire-7K3M\nspoof", "NearWire-7K3M\0spoof",
      "NearWire-7K3M\u{001B}spoof", "NearWire-7K3M\u{007F}spoof",
      "NearWire-7K3M\u{202E}spoof", "NearWire-7K3M\u{2066}spoof",
    ] {
      XCTAssertNil(
        NearWireBonjourServiceIdentity(
          instanceName: hostileName,
          type: NearWireBonjour.serviceType,
          domain: NearWireBonjour.localDomain,
          viewerDiscriminator: discriminator
        )
      )
    }
    XCTAssertNil(
      NearWireBonjourServiceIdentity(
        instanceName: String(repeating: "a", count: 64),
        type: NearWireBonjour.serviceType,
        domain: NearWireBonjour.localDomain,
        viewerDiscriminator: discriminator
      )
    )
    XCTAssertNil(NearWireBonjour.canonicalType("_other._tcp"))
    XCTAssertNil(NearWireBonjour.canonicalDomain("example.com."))
  }

  func testIdentityIgnoresInterfaceObservationsByConstruction() throws {
    let discriminator = ViewerDiscoveryDiscriminator(rawValue: "b3a97f874aad08bf")!
    let first = NearWireBonjourServiceIdentity(
      instanceName: "NearWire-7K3M",
      type: NearWireBonjour.serviceType,
      domain: NearWireBonjour.localDomain,
      viewerDiscriminator: discriminator
    )!
    let second = NearWireBonjourServiceIdentity(
      instanceName: "NearWire-7K3M",
      type: "_NEARWIRE._TCP",
      domain: "local",
      viewerDiscriminator: discriminator
    )!
    XCTAssertEqual(first, second)
    XCTAssertEqual(Set([first, second]).count, 1)
  }
}
