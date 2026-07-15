import AppKit
import CoreText
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

  func makeNSView(context: Context) -> ViewerBoundedTextScrollView {
    let editor = ViewerOperatorTextView(frame: .zero)
    configure(editor)
    editor.string = text

    let scrollView = ViewerBoundedTextScrollView(frame: .zero)
    scrollView.controlStyle = style
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

  func updateNSView(_ scrollView: ViewerBoundedTextScrollView, context: Context) {
    guard let editor = scrollView.documentView as? ViewerOperatorTextView else { return }
    scrollView.controlStyle = style
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

  static func dismantleNSView(_ scrollView: ViewerBoundedTextScrollView, coordinator: ()) {
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

@MainActor
final class ViewerBoundedTextScrollView: NSScrollView {
  var controlStyle: ViewerOperatorTextControlStyle = .singleLine

  override func layout() {
    super.layout()
    guard let editor = documentView as? ViewerOperatorTextView else { return }
    let viewport = contentView.bounds.size
    let width = max(viewport.width, 1)
    let height: CGFloat
    switch controlStyle {
    case .singleLine:
      height = max(viewport.height, 1)
    case .multiline:
      let measured = editor.layoutManager?.usedRect(for: editor.textContainer!).height ?? 0
      height = max(viewport.height, measured + editor.textContainerInset.height * 2)
    }
    if editor.frame.size != NSSize(width: width, height: height) {
      editor.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
    }
    editor.minSize = NSSize(width: width, height: max(viewport.height, 1))
    editor.maxSize = NSSize(
      width: width,
      height: controlStyle == .multiline ? .greatestFiniteMagnitude : max(viewport.height, 1)
    )
    editor.textContainer?.widthTracksTextView = true
    editor.textContainer?.containerSize = NSSize(
      width: width,
      height: controlStyle == .multiline ? .greatestFiniteMagnitude : max(viewport.height, 1)
    )
  }
}

/// Received Event text remains read-only. It permits only deliberate selection, Copy, and Select All.
@MainActor
final class ViewerReceivedEventTextView: NSTextView, CustomReflectable {
  private var ownedTextStorage: NSTextStorage?

  override var acceptsFirstResponder: Bool { true }

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
    switch item.action {
    case #selector(NSText.copy(_:)):
      return selectedRange().length > 0
    case #selector(NSText.selectAll(_:)):
      return !string.isEmpty
    default:
      return false
    }
  }

  override func dragSelection(
    with event: NSEvent,
    offset mouseOffset: NSSize,
    slideBack: Bool
  ) -> Bool {
    false
  }

  func updateMenu(copyTitle: String, selectAllTitle: String) {
    let menu = NSMenu()
    menu.addItem(
      withTitle: copyTitle,
      action: #selector(NSText.copy(_:)),
      keyEquivalent: ""
    )
    menu.addItem(
      withTitle: selectAllTitle,
      action: #selector(NSText.selectAll(_:)),
      keyEquivalent: ""
    )
    self.menu = menu
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
    isSelectable = true
    isRichText = false
    importsGraphics = false
    isAutomaticLinkDetectionEnabled = false
    displaysLinkToolTips = false
    usesFindPanel = false
    unregisterDraggedTypes()
    layoutManager?.allowsNonContiguousLayout = true
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
  @Environment(\.locale) private var locale
  let text: String
  let accessibilityText: String

  func makeNSView(context: Context) -> ViewerReceivedEventTextScrollView {
    let display = ViewerReceivedEventTextView(frame: .zero)
    _ = configure(display)

    let scrollView = ViewerReceivedEventTextScrollView(frame: .zero)
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.hasHorizontalScroller = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.documentView = display
    configureSizing(display, in: scrollView)
    scrollView.invalidateDocumentLayout()
    return scrollView
  }

  func updateNSView(_ scrollView: ViewerReceivedEventTextScrollView, context: Context) {
    guard let display = scrollView.documentView as? ViewerReceivedEventTextView else { return }
    if configure(display) {
      scrollView.invalidateDocumentLayout()
    }
    configureSizing(display, in: scrollView)
    scrollView.needsLayout = true
  }

  static func dismantleNSView(
    _ scrollView: ViewerReceivedEventTextScrollView,
    coordinator: ()
  ) {
    scrollView.cancelPendingMeasurement()
    (scrollView.documentView as? ViewerReceivedEventTextView)?.clearSensitiveState()
    scrollView.documentView = nil
  }

  private func configureSizing(_ display: ViewerReceivedEventTextView, in scrollView: NSScrollView)
  {
    let width = max(scrollView.contentSize.width, 1)
    display.minSize = NSSize(width: width, height: max(scrollView.contentSize.height, 1))
    display.maxSize = NSSize(
      width: width,
      height: CGFloat.greatestFiniteMagnitude
    )
    display.isHorizontallyResizable = false
    display.isVerticallyResizable = true
    display.autoresizingMask = [.width]
    display.textContainer?.widthTracksTextView = true
    display.textContainer?.containerSize = NSSize(
      width: width,
      height: CGFloat.greatestFiniteMagnitude
    )
  }

  @discardableResult
  private func configure(_ display: ViewerReceivedEventTextView) -> Bool {
    let textChanged = display.string != text
    if textChanged {
      display.string = text
      display.setSelectedRange(NSRange(location: 0, length: 0))
    }
    display.font = NSFont.monospacedSystemFont(
      ofSize: NSFont.systemFontSize,
      weight: NSFont.Weight.regular
    )
    display.setAccessibilityLabel(accessibilityText)
    display.updateMenu(
      copyTitle: ViewerLocalization.string("Copy", locale: locale),
      selectAllTitle: ViewerLocalization.string("Select All", locale: locale)
    )
    return textChanged
  }
}

@MainActor
final class ViewerReceivedEventTextScrollView: NSScrollView {
  private var contentRevision: UInt64 = 0
  private var requestedRevision: UInt64?
  private var requestedWidth: CGFloat?
  private var measuredHeight: CGFloat = 0
  private var measurementGeneration: UInt64 = 0
  private var measurementTask: Task<Void, Never>?
  private let measurementWorker = ViewerReceivedEventTextMeasurementWorker()

  func invalidateDocumentLayout() {
    contentRevision &+= 1
    measuredHeight = 0
    requestedRevision = nil
    requestedWidth = nil
    cancelPendingMeasurement()
    needsLayout = true
  }

  func cancelPendingMeasurement() {
    measurementGeneration &+= 1
    measurementTask?.cancel()
    measurementTask = nil
    measurementWorker.cancelPending()
  }

  override func layout() {
    super.layout()
    guard let display = documentView as? ViewerReceivedEventTextView else { return }
    let viewport = contentView.bounds.size
    let width = max(viewport.width, 1)
    if display.frame.width != width {
      display.frame.size.width = width
    }
    display.textContainer?.widthTracksTextView = true
    display.textContainer?.containerSize = NSSize(
      width: width,
      height: CGFloat.greatestFiniteMagnitude
    )
    let lineFragmentPadding = display.textContainer?.lineFragmentPadding ?? 0
    let measurementWidth = max(width - lineFragmentPadding * 2, 1)
    if requestedWidth != measurementWidth || requestedRevision != contentRevision {
      requestMeasurement(
        text: display.string,
        width: measurementWidth,
        fontSize: display.font?.pointSize ?? NSFont.systemFontSize
      )
    }
    let height = max(viewport.height, ceil(measuredHeight + display.textContainerInset.height * 2))
    let size = NSSize(width: width, height: height)
    if display.frame.size != size {
      display.frame = NSRect(origin: .zero, size: size)
    }
    display.minSize = NSSize(width: width, height: max(viewport.height, 1))
    display.maxSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
  }

  private func requestMeasurement(text: String, width: CGFloat, fontSize: CGFloat) {
    cancelPendingMeasurement()
    requestedWidth = width
    requestedRevision = contentRevision
    let generation = measurementGeneration
    let revision = contentRevision
    guard !text.isEmpty else {
      measuredHeight = 0
      return
    }
    measurementTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 120_000_000)
      guard let self, !Task.isCancelled, generation == measurementGeneration else { return }
      measurementTask = nil
      measurementWorker.submit(
        ViewerReceivedEventTextMeasurementRequest(
          text: text,
          width: width,
          fontSize: fontSize
        )
      ) { [weak self] height in
        Task { @MainActor [weak self] in
          guard let self, generation == measurementGeneration,
            revision == contentRevision, requestedWidth == width
          else { return }
          measuredHeight = height
          needsLayout = true
          layoutSubtreeIfNeeded()
        }
      }
    }
  }
}

struct ViewerReceivedEventTextMeasurementRequest: Sendable {
  let text: String
  let width: CGFloat
  let fontSize: CGFloat
}

final class ViewerReceivedEventTextMeasurementWorker: @unchecked Sendable {
  private struct Work: Sendable {
    let request: ViewerReceivedEventTextMeasurementRequest
    let completion: @Sendable (CGFloat) -> Void
  }

  private let lock = NSLock()
  private let measure: @Sendable (ViewerReceivedEventTextMeasurementRequest) -> CGFloat
  private var pending: Work?
  private var isRunning = false

  init(
    measure: @escaping @Sendable (ViewerReceivedEventTextMeasurementRequest) -> CGFloat = {
      ViewerReceivedEventTextMeasurement.height(
        text: $0.text,
        width: $0.width,
        fontSize: $0.fontSize
      )
    }
  ) {
    self.measure = measure
  }

  func submit(
    _ request: ViewerReceivedEventTextMeasurementRequest,
    completion: @escaping @Sendable (CGFloat) -> Void
  ) {
    let shouldStart: Bool
    lock.lock()
    pending = Work(request: request, completion: completion)
    if isRunning {
      shouldStart = false
    } else {
      isRunning = true
      shouldStart = true
    }
    lock.unlock()
    guard shouldStart else { return }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      self?.run()
    }
  }

  func cancelPending() {
    lock.lock()
    pending = nil
    lock.unlock()
  }

  var retainedWorkCountForTesting: Int {
    lock.lock()
    defer { lock.unlock() }
    return (isRunning ? 1 : 0) + (pending == nil ? 0 : 1)
  }

  private func run() {
    while let work = takeNext() {
      let height = measure(work.request)
      work.completion(height)
    }
  }

  private func takeNext() -> Work? {
    lock.lock()
    defer { lock.unlock() }
    guard let next = pending else {
      isRunning = false
      return nil
    }
    pending = nil
    return next
  }
}

enum ViewerReceivedEventTextMeasurement {
  nonisolated static func height(text: String, width: CGFloat, fontSize: CGFloat) -> CGFloat {
    let font = CTFontCreateWithName("SFMono-Regular" as CFString, fontSize, nil)
    let attributed = NSAttributedString(
      string: text,
      attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font
      ]
    )
    let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
    var fitRange = CFRange()
    let size = CTFramesetterSuggestFrameSizeWithConstraints(
      framesetter,
      CFRange(location: 0, length: 0),
      nil,
      CGSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude),
      &fitRange
    )
    return ceil(size.height)
  }
}
