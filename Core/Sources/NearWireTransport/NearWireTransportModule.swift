#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
#endif

enum NearWireTransportModule {
  static let isAvailable = true
}
