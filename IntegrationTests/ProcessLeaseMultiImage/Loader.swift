import Darwin
import Foundation

private typealias NamespaceFunction = @convention(c) () -> Int32
private typealias MonitorFunction = @convention(c) () -> UInt
private typealias ClaimFunction =
  @convention(c) (UnsafeMutablePointer<Int32>?) -> UnsafeMutableRawPointer?
private typealias HandleFunction = @convention(c) (UnsafeMutableRawPointer?) -> Void

private struct LeaseImage {
  let library: UnsafeMutableRawPointer
  let namespacesValid: NamespaceFunction
  let monitorIdentity: MonitorFunction
  let claim: ClaimFunction
  let release: HandleFunction
  let destroy: HandleFunction

  init(path: String, prefix: String) {
    guard let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
      fatalError("Could not load lease image at \(path).")
    }
    self.library = library
    namespacesValid = Self.load(library, symbol: "\(prefix)_namespaces_valid")
    monitorIdentity = Self.load(library, symbol: "\(prefix)_monitor_identity")
    claim = Self.load(library, symbol: "\(prefix)_claim")
    release = Self.load(library, symbol: "\(prefix)_release")
    destroy = Self.load(library, symbol: "\(prefix)_destroy")
  }

  private static func load<Function>(_ library: UnsafeMutableRawPointer, symbol: String) -> Function
  {
    guard let address = dlsym(library, symbol) else {
      fatalError("Could not load validation symbol \(symbol).")
    }
    return unsafeBitCast(address, to: Function.self)
  }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fatalError(message)
  }
}

guard CommandLine.arguments.count == 3 else {
  fatalError("Expected paths to two lease validation images.")
}

private let imageA = LeaseImage(path: CommandLine.arguments[1], prefix: "nearwire_lease_a")
private let imageB = LeaseImage(path: CommandLine.arguments[2], prefix: "nearwire_lease_b")

expect(imageA.namespacesValid() == 1, "Image A did not retain the permanent namespaces.")
expect(imageB.namespacesValid() == 1, "Image B did not retain the permanent namespaces.")
expect(imageA.monitorIdentity() != 0, "Image A did not resolve a private monitor.")
expect(
  imageA.monitorIdentity() == imageB.monitorIdentity(),
  "Independently loaded images did not resolve the same private monitor."
)

var statusA: Int32 = -1
guard let firstA = imageA.claim(&statusA) else {
  fatalError("Image A could not claim an empty registry; status \(statusA).")
}
expect(statusA == 0, "Image A returned an unexpected success status.")

var statusB: Int32 = -1
expect(imageB.claim(&statusB) == nil, "Image B claimed while image A owned the registry.")
expect(statusB == 1, "Image B did not return the contention status.")

imageA.release(firstA)
guard let firstB = imageB.claim(&statusB) else {
  fatalError("Image B could not claim after image A released; status \(statusB).")
}
expect(statusB == 0, "Image B returned an unexpected success status.")

imageA.release(firstA)
expect(imageA.claim(&statusA) == nil, "A stale image A release cleared image B ownership.")
expect(statusA == 1, "Image A did not observe image B contention.")

imageB.release(firstB)
imageB.destroy(firstB)

guard let secondA = imageA.claim(&statusA) else {
  fatalError("Image A could not reacquire after image B released; status \(statusA).")
}
expect(statusA == 0, "Image A returned an unexpected reacquisition status.")
imageA.release(secondA)
imageA.destroy(secondA)
imageA.destroy(firstA)

expect(dlclose(imageB.library) == 0, "Could not close image B.")
expect(dlclose(imageA.library) == 0, "Could not close image A.")
print("Process lease multi-image validation passed.")
