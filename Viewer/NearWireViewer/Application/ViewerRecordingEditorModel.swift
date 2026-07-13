import Foundation

@MainActor
final class ViewerRecordingEditorModel: ObservableObject, CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  @Published private(set) var revision: UInt64 = 0
  private(set) var buffers = ViewerExplorerOperatorTextBuffers()
  private(set) var validationMessage: String?

  init(name: String?, note: String?) {
    if let name {
      _ = replaceCharacters(
        field: .name,
        range: NSRange(location: 0, length: 0),
        replacement: name
      )
    }
    if let note {
      _ = replaceCharacters(
        field: .note,
        range: NSRange(location: 0, length: 0),
        replacement: note
      )
    }
    validationMessage = nil
  }

  var name: String { buffers.name.value }
  var note: String { buffers.note.value }
  var annotation: String { buffers.annotation.value }

  @discardableResult
  func replaceWhole(_ field: ViewerExplorerOperatorTextField, with value: String) -> Bool {
    let length: Int
    switch field {
    case .name: length = buffers.name.utf16Count
    case .note: length = buffers.note.utf16Count
    case .annotation: length = buffers.annotation.utf16Count
    case .search, .jsonPath, .jsonComparison:
      validationMessage = "This editor does not own that field."
      publish()
      return false
    }
    return replaceCharacters(
      field: field,
      range: NSRange(location: 0, length: length),
      replacement: value
    )
  }

  @discardableResult
  func replaceCharacters(
    field: ViewerExplorerOperatorTextField,
    range: NSRange,
    replacement: String
  ) -> Bool {
    guard [.name, .note, .annotation].contains(field) else {
      validationMessage = "This editor does not own that field."
      publish()
      return false
    }
    switch buffers.replaceCharacters(field: field, range: range, replacement: replacement) {
    case .applied:
      validationMessage = nil
      publish()
      return true
    case .rejected:
      validationMessage = "The recording text exceeds its supported byte or character limit."
      publish()
      return false
    }
  }

  func clearAnnotation() {
    _ = replaceWhole(.annotation, with: "")
  }

  nonisolated var description: String { "ViewerRecordingEditorModel(redacted)" }
  nonisolated var debugDescription: String { description }
  nonisolated var customMirror: Mirror {
    Mirror(self, children: [:], displayStyle: .class)
  }

  private func publish() {
    revision = revision == UInt64.max ? 1 : revision + 1
  }
}
