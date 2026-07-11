import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireTransport
#endif

final class SDKSessionChannelIngress: @unchecked Sendable {
  enum Item: Sendable {
    case channel(SecureByteChannelEvent)
    case overflow

    fileprivate var receiveByteCount: Int {
      if case .channel(.received(let data)) = self { return data.count }
      return 0
    }

    fileprivate var isTerminal: Bool {
      switch self {
      case .channel(.terminated), .overflow:
        return true
      case .channel(.stateChanged), .channel(.received), .channel(.sendCompleted):
        return false
      }
    }
  }

  struct RetainedCounts: Equatable, Sendable {
    let events: Int
    let receiveBytes: Int
  }

  private let lock = NSLock()
  private let maximumEvents: Int
  private let maximumReceiveBytes: Int
  private var pending: [Item] = []
  private var retainedEventCount = 0
  private var retainedReceiveBytes = 0
  private var drain: (@Sendable () -> Void)?
  private var drainScheduled = false
  private var terminalLatched = false
  private var stopped = false

  init(maximumEvents: Int, maximumReceiveBytes: Int) {
    self.maximumEvents = maximumEvents
    self.maximumReceiveBytes = maximumReceiveBytes
  }

  func installDrain(_ drain: @escaping @Sendable () -> Void) {
    var shouldSchedule = false
    lock.lock()
    if !stopped, self.drain == nil {
      self.drain = drain
      if !pending.isEmpty, !drainScheduled {
        drainScheduled = true
        shouldSchedule = true
      }
    }
    lock.unlock()
    if shouldSchedule { drain() }
  }

  func submit(_ item: Item) {
    var callback: (@Sendable () -> Void)?
    lock.lock()
    guard !stopped, !terminalLatched else {
      lock.unlock()
      return
    }

    if item.isTerminal {
      releasePendingNonterminalAccounting()
      pending.removeAll(keepingCapacity: false)
      pending.append(item)
      terminalLatched = true
    } else {
      let (newByteCount, byteOverflow) = retainedReceiveBytes.addingReportingOverflow(
        item.receiveByteCount
      )
      let (newEventCount, eventOverflow) = retainedEventCount.addingReportingOverflow(1)
      if byteOverflow || eventOverflow || newEventCount > maximumEvents
        || newByteCount > maximumReceiveBytes
      {
        releasePendingNonterminalAccounting()
        pending.removeAll(keepingCapacity: false)
        pending.append(.overflow)
        terminalLatched = true
      } else {
        pending.append(item)
        retainedEventCount = newEventCount
        retainedReceiveBytes = newByteCount
      }
    }

    if !drainScheduled, let drain {
      drainScheduled = true
      callback = drain
    }
    lock.unlock()
    callback?()
  }

  func takeBatch(maximumItems: Int) -> [Item]? {
    lock.lock()
    defer { lock.unlock() }
    guard !stopped else {
      drainScheduled = false
      return nil
    }
    guard !pending.isEmpty else {
      drainScheduled = false
      return nil
    }
    let count = min(maximumItems, pending.count)
    let result = Array(pending.prefix(count))
    pending.removeFirst(count)
    return result
  }

  func completeBatch(_ batch: [Item]) {
    lock.lock()
    defer { lock.unlock() }
    guard !stopped else { return }
    for item in batch where !item.isTerminal {
      retainedEventCount -= 1
      retainedReceiveBytes -= item.receiveByteCount
    }
  }

  func finishDrainTurn() {
    var callback: (@Sendable () -> Void)?
    lock.lock()
    drainScheduled = false
    if !stopped, !pending.isEmpty, let drain {
      drainScheduled = true
      callback = drain
    }
    lock.unlock()
    callback?()
  }

  var latchedTerminal: Item? {
    lock.lock()
    defer { lock.unlock() }
    guard terminalLatched else { return nil }
    return pending.last
  }

  func stop() {
    lock.lock()
    stopped = true
    drain = nil
    pending.removeAll(keepingCapacity: false)
    retainedEventCount = 0
    retainedReceiveBytes = 0
    drainScheduled = false
    lock.unlock()
  }

  var retainedCounts: RetainedCounts {
    lock.lock()
    defer { lock.unlock() }
    return RetainedCounts(events: retainedEventCount, receiveBytes: retainedReceiveBytes)
  }

  private func releasePendingNonterminalAccounting() {
    for item in pending where !item.isTerminal {
      retainedEventCount -= 1
      retainedReceiveBytes -= item.receiveByteCount
    }
  }
}
