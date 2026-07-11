#if SWIFT_PACKAGE
  import NearWire
  @_spi(NearWireInternal) import NearWireCore
#endif

enum NearWirePerformanceModule {
  static let isAvailable = true
}
