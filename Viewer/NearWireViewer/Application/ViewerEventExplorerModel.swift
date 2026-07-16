import Foundation

enum ViewerExplorerEventIdentity: Equatable, Hashable, Sendable {
  case memory(ViewerEventJournalKey)
}

enum ViewerExplorerTraversalReason: Equatable, Sendable {
  case initialLoad
  case filterChange
  case deviceSelection
  case resume
  case jumpToLatest
  case refresh
  case exactReveal
}

enum ViewerExplorerTraversalState: Equatable, Sendable {
  case idle
  case paused
  case loading(ViewerExplorerTraversalReason)
  case ready(ViewerExplorerTraversalReason)
  case failed(ViewerExplorerFailure)
}

enum ViewerExplorerLimits {
  static let maximumSelectedDevices = 16
}
