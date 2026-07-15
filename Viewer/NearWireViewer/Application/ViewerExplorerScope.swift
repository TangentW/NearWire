import Foundation

enum ViewerExplorerScopeError: Error, Equatable, Sendable {
  case invalidScope
  case invalidFilter
}

struct ViewerExplorerFilter: Equatable, Sendable {
  let predicates: [ViewerEventPredicate]

  init(predicates: [ViewerEventPredicate] = []) throws {
    guard predicates.count <= 32 else { throw ViewerExplorerScopeError.invalidFilter }
    do {
      _ = try ViewerLiveEvaluationRequest(runtimeLogicalID: UUID(), predicates: predicates)
    } catch {
      throw ViewerExplorerScopeError.invalidFilter
    }
    self.predicates = predicates
  }
}

extension ViewerExplorerFilter: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExplorerFilter(redacted, predicates: \(predicates.count))" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["predicateCount": predicates.count], displayStyle: .struct)
  }
}
