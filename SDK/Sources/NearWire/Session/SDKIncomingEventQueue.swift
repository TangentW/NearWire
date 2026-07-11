import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
  @_spi(NearWireInternal) import NearWireTransport
#endif

struct SDKIncomingEventItem: Equatable, Sendable {
  let received: WireReceivedEvent
  let encodedByteCount: Int
}

struct SDKIncomingEventQueue: Sendable {
  struct Snapshot: Equatable, Sendable {
    let count: Int
    let encodedBytes: Int
    let heapNodeCount: Int
    let nextDeadlineNanoseconds: UInt64?
  }

  private struct Node: Sendable {
    let item: SDKIncomingEventItem
    var previous: EventID?
    var next: EventID?
  }

  private struct HeapNode: Comparable, Sendable {
    let deadline: UInt64
    let ordinal: UInt64
    let id: EventID

    static func < (lhs: Self, rhs: Self) -> Bool {
      if lhs.deadline != rhs.deadline { return lhs.deadline < rhs.deadline }
      return lhs.ordinal < rhs.ordinal
    }
  }

  let maximumCount: Int
  let maximumEncodedBytes: Int
  private var nodes: [EventID: Node] = [:]
  private var head: EventID?
  private var tail: EventID?
  private var heap: [HeapNode] = []
  private var heapIndices: [EventID: Int] = [:]
  private var encodedBytes = 0
  private var nextOrdinal: UInt64 = 0

  init(maximumCount: Int, maximumEncodedBytes: Int) {
    self.maximumCount = maximumCount
    self.maximumEncodedBytes = maximumEncodedBytes
  }

  mutating func appendAtomically(_ items: [SDKIncomingEventItem]) throws {
    guard !items.isEmpty else { return }
    var incomingBytes = 0
    var incomingIDs = Set<EventID>()
    for item in items {
      guard item.encodedByteCount > 0, incomingIDs.insert(item.received.envelope.id).inserted,
        nodes[item.received.envelope.id] == nil
      else { throw SDKSessionAdmissionError(.protocolViolation) }
      let (sum, overflow) = incomingBytes.addingReportingOverflow(item.encodedByteCount)
      guard !overflow else { throw SDKSessionAdmissionError(.activeIngressOverflow) }
      incomingBytes = sum
    }
    let (newCount, countOverflow) = nodes.count.addingReportingOverflow(items.count)
    let (newBytes, byteOverflow) = encodedBytes.addingReportingOverflow(incomingBytes)
    let ordinalCapacity = UInt64.max - nextOrdinal
    guard !countOverflow, !byteOverflow, newCount <= maximumCount,
      newBytes <= maximumEncodedBytes, UInt64(items.count) <= ordinalCapacity
    else { throw SDKSessionAdmissionError(.activeIngressOverflow) }

    for item in items { appendPrevalidated(item) }
  }

  mutating func popHead() -> SDKIncomingEventItem? {
    guard let head else { return nil }
    return remove(id: head)
  }

  mutating func removeExpired(nowNanoseconds: UInt64, maximumCount: Int) throws -> [EventID] {
    guard maximumCount > 0 else { throw SDKSessionAdmissionError(.invalidLocalConfiguration) }
    var removed: [EventID] = []
    while removed.count < maximumCount, let first = heap.first, first.deadline <= nowNanoseconds {
      guard let item = remove(id: first.id) else {
        throw SDKSessionAdmissionError(.protocolViolation)
      }
      if nowNanoseconds < item.received.receivedAtNanoseconds {
        throw SDKSessionAdmissionError(.clockFailed)
      }
      removed.append(first.id)
    }
    return removed
  }

  var first: SDKIncomingEventItem? {
    head.flatMap { nodes[$0]?.item }
  }

  var snapshot: Snapshot {
    Snapshot(
      count: nodes.count,
      encodedBytes: encodedBytes,
      heapNodeCount: heap.count,
      nextDeadlineNanoseconds: heap.first?.deadline
    )
  }

  mutating func removeAll() {
    nodes.removeAll(keepingCapacity: false)
    heap.removeAll(keepingCapacity: false)
    heapIndices.removeAll(keepingCapacity: false)
    head = nil
    tail = nil
    encodedBytes = 0
  }

  private mutating func appendPrevalidated(_ item: SDKIncomingEventItem) {
    let id = item.received.envelope.id
    nodes[id] = Node(item: item, previous: tail, next: nil)
    if let tail {
      nodes[tail]?.next = id
    } else {
      head = id
    }
    self.tail = id
    encodedBytes += item.encodedByteCount
    let heapNode = HeapNode(
      deadline: item.received.deadlineNanoseconds,
      ordinal: nextOrdinal,
      id: id
    )
    nextOrdinal += 1
    heap.append(heapNode)
    heapIndices[id] = heap.count - 1
    siftUp(from: heap.count - 1)
  }

  private mutating func remove(id: EventID) -> SDKIncomingEventItem? {
    guard let node = nodes.removeValue(forKey: id), let heapIndex = heapIndices[id] else {
      return nil
    }
    if let previous = node.previous {
      nodes[previous]?.next = node.next
    } else {
      head = node.next
    }
    if let next = node.next {
      nodes[next]?.previous = node.previous
    } else {
      tail = node.previous
    }
    encodedBytes -= node.item.encodedByteCount
    removeHeap(at: heapIndex)
    return node.item
  }

  private mutating func removeHeap(at index: Int) {
    let removedID = heap[index].id
    let last = heap.removeLast()
    heapIndices.removeValue(forKey: removedID)
    guard index < heap.count else { return }
    heap[index] = last
    heapIndices[last.id] = index
    if index > 0, heap[index] < heap[(index - 1) / 2] {
      siftUp(from: index)
    } else {
      siftDown(from: index)
    }
  }

  private mutating func siftUp(from start: Int) {
    var child = start
    while child > 0 {
      let parent = (child - 1) / 2
      guard heap[child] < heap[parent] else { break }
      swapHeap(child, parent)
      child = parent
    }
  }

  private mutating func siftDown(from start: Int) {
    var parent = start
    while true {
      let left = parent * 2 + 1
      guard left < heap.count else { return }
      let right = left + 1
      let child = right < heap.count && heap[right] < heap[left] ? right : left
      guard heap[child] < heap[parent] else { return }
      swapHeap(child, parent)
      parent = child
    }
  }

  private mutating func swapHeap(_ lhs: Int, _ rhs: Int) {
    heap.swapAt(lhs, rhs)
    heapIndices[heap[lhs].id] = lhs
    heapIndices[heap[rhs].id] = rhs
  }
}
