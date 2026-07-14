import CryptoKit
import Foundation
import Network
import Security

@_spi(NearWireInternal) public struct ViewerTransportIdentity: @unchecked Sendable {
  fileprivate let protocolIdentity: sec_identity_t

  public init(identity: SecIdentity) throws {
    try self.init(identity: identity, adapter: sec_identity_create)
  }

  init(
    identity: SecIdentity,
    adapter: (SecIdentity) -> sec_identity_t?
  ) throws {
    guard let protocolIdentity = adapter(identity) else {
      throw SecureTransportError(
        code: .identityAdaptationFailed,
        path: "identity",
        message: "Security could not adapt the Viewer identity."
      )
    }
    self.protocolIdentity = protocolIdentity
  }
}

enum SecureNetworkParameters {
  static let applicationProtocol = "nearwire/1"
  static let keepaliveIdleSeconds = 10
  static let keepaliveIntervalSeconds = 5
  static let keepaliveProbeCount = 3

  static func appClient(
    limits: SecureTransportLimits = .default,
    verificationQueue: DispatchQueue
  ) -> NWParameters {
    let tls = configuredTLSOptions()
    sec_protocol_options_set_verify_block(
      tls.securityProtocolOptions,
      { _, trust, completion in
        let trustReference = sec_trust_copy_ref(trust)
        ConnectionLocalViewerTrust.completeVerification(
          trustReference.takeRetainedValue(),
          completion: completion
        )
      },
      verificationQueue
    )
    return configuredParameters(tls: tls, limits: limits)
  }

  static func viewerServer(
    identity: ViewerTransportIdentity,
    limits: SecureTransportLimits = .default
  ) -> NWParameters {
    let tls = configuredTLSOptions()
    sec_protocol_options_set_local_identity(
      tls.securityProtocolOptions,
      identity.protocolIdentity
    )
    return configuredParameters(tls: tls, limits: limits)
  }

  private static func configuredTLSOptions() -> NWProtocolTLS.Options {
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_min_tls_protocol_version(
      tls.securityProtocolOptions,
      .TLSv13
    )
    sec_protocol_options_set_max_tls_protocol_version(
      tls.securityProtocolOptions,
      .TLSv13
    )
    sec_protocol_options_add_tls_application_protocol(
      tls.securityProtocolOptions,
      applicationProtocol
    )
    return tls
  }

  private static func configuredParameters(
    tls: NWProtocolTLS.Options,
    limits: SecureTransportLimits
  ) -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = keepaliveIdleSeconds
    tcp.keepaliveInterval = keepaliveIntervalSeconds
    tcp.keepaliveCount = keepaliveProbeCount
    tcp.connectionTimeout = limits.connectionTimeoutSeconds
    let parameters = NWParameters(tls: tls, tcp: tcp)
    parameters.includePeerToPeer = true
    return parameters
  }
}

@_spi(NearWireInternal) public enum ConnectionLocalViewerTrust {
  public static func evaluate(_ trust: SecTrust) -> Bool {
    evaluate(trust, security: .live)
  }

  static func completeVerification(
    _ trust: SecTrust,
    security: ConnectionLocalTrustSecurity = .live,
    completion: (Bool) -> Void
  ) {
    completion(evaluate(trust, security: security))
  }

  static func evaluate(
    _ trust: SecTrust,
    security: ConnectionLocalTrustSecurity
  ) -> Bool {
    guard let certificates = security.certificateChain(trust),
      let certificate = certificates.first
    else {
      return false
    }
    let anchors = [certificate] as CFArray
    guard security.setBasicX509Policy(trust) == errSecSuccess,
      security.setAnchorCertificates(trust, anchors) == errSecSuccess,
      security.setAnchorCertificatesOnly(trust, true) == errSecSuccess
    else {
      return false
    }
    return security.evaluate(trust)
  }

  public static func fingerprintSHA256(_ certificate: SecCertificate) -> String {
    let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

struct ConnectionLocalTrustSecurity: @unchecked Sendable {
  static let live = ConnectionLocalTrustSecurity(
    certificateChain: { trust in
      SecTrustCopyCertificateChain(trust) as? [SecCertificate]
    },
    setBasicX509Policy: { trust in
      SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
    },
    setAnchorCertificates: { trust, anchors in
      SecTrustSetAnchorCertificates(trust, anchors)
    },
    setAnchorCertificatesOnly: { trust, anchorOnly in
      SecTrustSetAnchorCertificatesOnly(trust, anchorOnly)
    },
    evaluate: { trust in
      var error: CFError?
      return SecTrustEvaluateWithError(trust, &error)
    }
  )

  let certificateChain: (SecTrust) -> [SecCertificate]?
  let setBasicX509Policy: (SecTrust) -> OSStatus
  let setAnchorCertificates: (SecTrust, CFArray) -> OSStatus
  let setAnchorCertificatesOnly: (SecTrust, Bool) -> OSStatus
  let evaluate: (SecTrust) -> Bool
}
