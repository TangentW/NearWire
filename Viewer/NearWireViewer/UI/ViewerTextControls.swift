import AppKit
import SwiftUI

enum ViewerOperatorTextControlStyle: Equatable, Sendable {
  case singleLine
  case multiline
}

/// A native AppKit editor that asks the owning bounded model about the exact UTF-16 edit range
/// before AppKit stores it. System copy, cut, and paste remain ordinary user-invoked editor actions.
@MainActor
final class ViewerOperatorTextView: NSTextView, NSTextViewDelegate, CustomReflectable {
  var controlStyle: ViewerOperatorTextControlStyle = .singleLine
  var onBoundedEdit: ((NSRange, String) -> Bool)?
  var onSubmit: (() -> Void)?
  private(set) var isProcessingNativeEdit = false
  private var ownedTextStorage: NSTextStorage?

  override convenience init(frame frameRect: NSRect) {
    self.init(frame: frameRect, textContainer: nil)
  }

  override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
    let textSystem = Self.makeTextSystem(size: frameRect.size, suppliedContainer: container)
    super.init(frame: frameRect, textContainer: textSystem.container)
    ownedTextStorage = textSystem.storage
    configure()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configure()
  }

  func textView(
    _ textView: NSTextView,
    shouldChangeTextIn affectedCharRange: NSRange,
    replacementString: String?
  ) -> Bool {
    let replacement = replacementString ?? ""
    if controlStyle == .singleLine,
      replacement.unicodeScalars.contains(where: CharacterSet.newlines.contains)
    {
      return false
    }
    isProcessingNativeEdit = true
    defer { isProcessingNativeEdit = false }
    return onBoundedEdit?(affectedCharRange, replacement) ?? false
  }

  func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    guard controlStyle == .singleLine, commandSelector == #selector(NSResponder.insertNewline(_:))
    else { return false }
    onSubmit?()
    return true
  }

  func clearSensitiveState() {
    onBoundedEdit = nil
    onSubmit = nil
    string = ""
    setAccessibilityLabel(nil)
    setAccessibilityHelp(nil)
  }

  override var description: String { "ViewerOperatorTextView(redacted)" }
  override var debugDescription: String { description }
  nonisolated var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }

  private func configure() {
    delegate = self
    isEditable = true
    isSelectable = true
    isRichText = false
    importsGraphics = false
    isAutomaticQuoteSubstitutionEnabled = false
    isAutomaticDashSubstitutionEnabled = false
    isAutomaticTextReplacementEnabled = false
    isAutomaticSpellingCorrectionEnabled = false
    isAutomaticLinkDetectionEnabled = false
    isContinuousSpellCheckingEnabled = false
    isGrammarCheckingEnabled = false
    usesFindPanel = false
    drawsBackground = false
    textContainerInset = NSSize(width: 5, height: 4)
    font = .systemFont(ofSize: NSFont.systemFontSize)
  }

  private static func makeTextSystem(
    size: NSSize,
    suppliedContainer: NSTextContainer?
  ) -> (container: NSTextContainer, storage: NSTextStorage?) {
    if let suppliedContainer { return (suppliedContainer, nil) }
    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(
      containerSize: NSSize(
        width: max(size.width, 1),
        height: CGFloat.greatestFiniteMagnitude
      )
    )
    storage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(container)
    return (container, storage)
  }
}

struct ViewerBoundedTextInput: NSViewRepresentable {
  let text: String
  let style: ViewerOperatorTextControlStyle
  let accessibilityLabel: String
  var accessibilityHelp: String?
  var monospaced = false
  var onEdit: (NSRange, String) -> Bool
  var onSubmit: () -> Void = {}

  func makeNSView(context: Context) -> NSScrollView {
    let editor = ViewerOperatorTextView(frame: .zero)
    configure(editor)
    editor.string = text

    let scrollView = NSScrollView(frame: .zero)
    scrollView.borderType = .bezelBorder
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .textBackgroundColor
    scrollView.hasHorizontalScroller = false
    scrollView.hasVerticalScroller = style == .multiline
    scrollView.autohidesScrollers = true
    scrollView.documentView = editor
    configureSizing(editor, in: scrollView)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let editor = scrollView.documentView as? ViewerOperatorTextView else { return }
    configure(editor)
    configureSizing(editor, in: scrollView)
    guard !editor.isProcessingNativeEdit else { return }
    guard editor.string != text else { return }
    let selection = editor.selectedRange()
    editor.string = text
    editor.setSelectedRange(
      NSRange(location: min(selection.location, text.utf16.count), length: 0)
    )
  }

  static func dismantleNSView(_ scrollView: NSScrollView, coordinator: ()) {
    (scrollView.documentView as? ViewerOperatorTextView)?.clearSensitiveState()
    scrollView.documentView = nil
  }

  private func configure(_ editor: ViewerOperatorTextView) {
    editor.controlStyle = style
    editor.onBoundedEdit = onEdit
    editor.onSubmit = onSubmit
    editor.font =
      monospaced
      ? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
      : .systemFont(ofSize: NSFont.systemFontSize)
    editor.setAccessibilityLabel(accessibilityLabel)
    editor.setAccessibilityHelp(accessibilityHelp)
  }

  private func configureSizing(_ editor: ViewerOperatorTextView, in scrollView: NSScrollView) {
    let contentSize = scrollView.contentSize
    editor.minSize = NSSize(width: 0, height: contentSize.height)
    editor.maxSize = NSSize(
      width: max(contentSize.width, 1),
      height: style == .multiline ? .greatestFiniteMagnitude : max(contentSize.height, 1)
    )
    editor.isHorizontallyResizable = false
    editor.isVerticallyResizable = style == .multiline
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    editor.textContainer?.containerSize = NSSize(
      width: max(contentSize.width, 1),
      height: style == .multiline ? .greatestFiniteMagnitude : max(contentSize.height, 1)
    )
  }
}

/// Received or stored Event text is deliberately display-only. It has no selection, editing,
/// contextual menu, drag registration, or validated responder command that can reach a pasteboard.
@MainActor
final class ViewerReceivedEventTextView: NSTextView, CustomReflectable {
  private var ownedTextStorage: NSTextStorage?

  override var acceptsFirstResponder: Bool { false }

  override convenience init(frame frameRect: NSRect) {
    self.init(frame: frameRect, textContainer: nil)
  }

  override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
    let textSystem = Self.makeTextSystem(size: frameRect.size, suppliedContainer: container)
    super.init(frame: frameRect, textContainer: textSystem.container)
    ownedTextStorage = textSystem.storage
    configure()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configure()
  }

  override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
    false
  }

  func clearSensitiveState() {
    string = ""
    setAccessibilityLabel(nil)
  }

  override var description: String { "ViewerReceivedEventTextView(redacted)" }
  override var debugDescription: String { description }
  nonisolated var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }

  private func configure() {
    isEditable = false
    isSelectable = false
    isRichText = false
    importsGraphics = false
    isAutomaticLinkDetectionEnabled = false
    displaysLinkToolTips = false
    usesFindPanel = false
    menu = nil
    unregisterDraggedTypes()
    drawsBackground = false
    textContainerInset = NSSize(width: 8, height: 8)
  }

  private static func makeTextSystem(
    size: NSSize,
    suppliedContainer: NSTextContainer?
  ) -> (container: NSTextContainer, storage: NSTextStorage?) {
    if let suppliedContainer { return (suppliedContainer, nil) }
    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(
      containerSize: NSSize(
        width: max(size.width, 1),
        height: CGFloat.greatestFiniteMagnitude
      )
    )
    storage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(container)
    return (container, storage)
  }
}

struct ViewerReceivedEventText: NSViewRepresentable {
  let text: String
  let accessibilityText: String

  func makeNSView(context: Context) -> NSScrollView {
    let display = ViewerReceivedEventTextView(frame: .zero)
    display.string = text
    display.font = NSFont.monospacedSystemFont(
      ofSize: NSFont.systemFontSize,
      weight: NSFont.Weight.regular
    )
    display.setAccessibilityLabel(accessibilityText)

    let scrollView = NSScrollView(frame: .zero)
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.hasHorizontalScroller = true
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.documentView = display
    configureSizing(display, in: scrollView)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let display = scrollView.documentView as? ViewerReceivedEventTextView else { return }
    if display.string != text { display.string = text }
    display.setAccessibilityLabel(accessibilityText)
    configureSizing(display, in: scrollView)
  }

  static func dismantleNSView(_ scrollView: NSScrollView, coordinator: ()) {
    (scrollView.documentView as? ViewerReceivedEventTextView)?.clearSensitiveState()
    scrollView.documentView = nil
  }

  private func configureSizing(_ display: ViewerReceivedEventTextView, in scrollView: NSScrollView)
  {
    display.minSize = scrollView.contentSize
    display.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    display.isHorizontallyResizable = true
    display.isVerticallyResizable = true
    display.autoresizingMask = []
    display.textContainer?.widthTracksTextView = false
    display.textContainer?.containerSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
  }
}
