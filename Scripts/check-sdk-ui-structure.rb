#!/usr/bin/env ruby

root = File.expand_path("..", __dir__)
source_root = File.join(root, "SDK", "Sources", "NearWireUI")
paths = Dir[File.join(source_root, "*.swift")].sort
abort "NearWireUI source is unavailable." if paths.empty?

source = paths.map { |path| File.read(path) }.join("\n")

class NearWireUIStructureError < StandardError; end

def assert_ui(condition, message)
  raise NearWireUIStructureError, message unless condition
end

def validate_ui(source)
  public_types = source.scan(/^public struct (\w+)/).flatten.sort
  assert_ui(
    public_types == %w[NearWireConnectionStatusView NearWireConnectionView],
    "NearWireUI public type inventory changed: #{public_types.inspect}"
  )
  assert_ui(
    source.scan(/^  public init\(/).length == 2,
    "NearWireUI must expose exactly two public initializers."
  )
  assert_ui(
    source.scan(/^  public var body: some View/).length == 2,
    "NearWireUI must expose exactly two public View bodies."
  )
  public_lines = source.lines.map(&:strip).select { |line| line.start_with?("public ") }
  allowed_public_lines = [
    "public struct NearWireConnectionStatusView: View {",
    "public struct NearWireConnectionView: View {",
    "public init(status: NearWireConnectionStatus) {",
    "public init(nearWire: NearWire) {",
    "public var body: some View {",
    "public var body: some View {",
  ].sort
  assert_ui(
    public_lines.sort == allowed_public_lines,
    "NearWireUI public declaration lines changed: #{public_lines.inspect}"
  )
  public_declaration_kinds = source.scan(
    /\bpublic\s+(?:nonisolated\s+|static\s+|class\s+)*(struct|class|actor|enum|protocol|extension|typealias|init|var|let|func|subscript)\b/
  ).flatten.sort
  assert_ui(
    public_declaration_kinds == %w[init init struct struct var var],
    "NearWireUI public declaration kinds changed: #{public_declaration_kinds.inspect}"
  )
  assert_ui(
    !source.match?(/\bextension\s+NearWireConnection(?:Status)?View\b/),
    "Supported NearWireUI views must not gain extension declarations."
  )
  assert_ui(
    !source.match?(/@\w+(?:\([^\n]*\))?\s*(?:\n\s*)?public\s/),
    "Supported NearWireUI declarations must not gain source-authored attributes."
  )

  forbidden_public = %w[
    NearWireUIConnectionControlling NearWireUIConnectionModel NearWireUIInputLimiter
    NearWireUIOperationCoordinator NearWireUIOperationPhase NearWireUIStatusPresentation
  ]
  forbidden_public.each do |name|
    assert_ui(!source.match?(/^public .*\b#{name}\b/), "Internal UI type became public: #{name}")
  end

  forbidden_tokens = %w[
    UIKit AppKit Combine UserDefaults Keychain SecItem UIPasteboard NSPasteboard AVCapture
    NWPathMonitor NotificationCenter UIApplication NSApplication BGTask analytics
  ]
  forbidden_tokens.each do |token|
    assert_ui(!source.include?(token), "NearWireUI contains forbidden API token: #{token}")
  end

  assert_ui(!source.include?("@_spi"), "NearWireUI must not expose or import SPI.")
  assert_ui(!source.include?("Task.detached"), "NearWireUI must not detach Tasks.")
  imports = source.scan(/^\s*import\s+(\w+)/).flatten.uniq.sort
  assert_ui(
    imports == %w[Foundation NearWire SwiftUI],
    "NearWireUI import boundary changed: #{imports.inspect}"
  )
  assert_ui(source.include?("ObjectIdentifier(nearWire)"), "Injected NearWire identity is missing.")
  assert_ui(source.include?(".id(stateIdentity)"), "Injected NearWire identity reset is missing.")
  assert_ui(source.include?(".bufferingNewest(1)"), "Coordinator phase buffering must remain one value.")
  assert_ui(
    source.include?(".accessibilityLabel(Text(verbatim: presentation.accessibilityLabel))"),
    "Closed status accessibility label binding is missing."
  )
  assert_ui(source.include?(".accessibilityHint"), "NearWireUI accessibility hints are missing.")
  assert_ui(source.include?(".autocorrectionDisabled()"), "Pairing input must disable autocorrection.")
  localizable_literals = [
    /\bText\("/,
    /\bButton\("/,
    /\.accessibilityLabel\("/,
    /\.accessibilityHint\("/,
  ]
  assert_ui(
    localizable_literals.none? { |pattern| source.match?(pattern) },
    "NearWireUI fixed-English strings must use verbatim SwiftUI APIs."
  )
end

begin
  validate_ui(source)
  if ARGV == ["--self-test"]
    mutations = {
      "extra public top-level type" => source + "\npublic enum ExtraUI {}\n",
      "extra public member" => source.sub(
        "public var body: some View {",
        "public func extra() {}\n  public var body: some View {"
      ),
      "attributed public member" => source +
        "\nextension NearWireConnectionView { @MainActor public func extra() {} }\n",
      "extra marker conformance" => source +
        "\nextension NearWireConnectionView: Equatable {}\n",
      "attribute on supported view" => source.sub(
        "public struct NearWireConnectionView: View {",
        "@MainActor\npublic struct NearWireConnectionView: View {"
      ),
    }
    mutations.each do |name, mutated|
      begin
        validate_ui(mutated)
      rescue NearWireUIStructureError
        next
      end
      raise NearWireUIStructureError, "Mutation unexpectedly passed: #{name}"
    end
    puts "NearWireUI structure mutation tests passed."
  else
    puts "NearWireUI structure and resource boundary passed."
  end
rescue NearWireUIStructureError => error
  warn error.message
  exit 1
end
