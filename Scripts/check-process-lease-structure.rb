#!/usr/bin/env ruby

source_path = ARGV.fetch(0, "SDK/Sources/NearWire/Session/ProcessConnectionLease.swift")
source = File.read(source_path)
violations = []

def section(source, start_marker, end_marker)
  start_index = source.index(start_marker)
  return nil unless start_index

  end_index = source.index(end_marker, start_index + start_marker.length)
  return nil unless end_index

  source[start_index...end_index]
end

def require_order(section, markers, label, violations)
  unless section
    violations << "Missing #{label} section."
    return
  end

  cursor = 0
  markers.each do |marker|
    index = section.index(marker, cursor)
    unless index
      violations << "#{label} is missing or misorders: #{marker}"
      return
    end
    cursor = index + marker.length
  end
end

def reject_between(section, start_marker, end_marker, tokens, label, violations)
  unless section
    violations << "Missing #{label} section."
    return
  end

  start_index = section.index(start_marker)
  end_index = start_index && section.index(end_marker, start_index + start_marker.length)
  unless start_index && end_index
    violations << "#{label} does not expose the required audit boundaries."
    return
  end

  fragment = section[start_index...end_index]
  tokens.each do |token|
    violations << "#{label} contains forbidden work before its boundary: #{token}" \
      if fragment.include?(token)
  end
end

def declaration_bodies(source, type_name)
  pattern = /\b(?:struct|extension)\s+#{Regexp.escape(type_name)}\b/
  bodies = []
  cursor = 0

  while (match = source.match(pattern, cursor))
    opening = source.index("{", match.end(0))
    break unless opening

    depth = 0
    closing = nil
    index = opening
    while index < source.length
      case source[index]
      when "{"
        depth += 1
      when "}"
        depth -= 1
        if depth.zero?
          closing = index
          break
        end
      end
      index += 1
    end
    break unless closing

    bodies << source[opening..closing]
    cursor = closing + 1
  end
  bodies
end

forbidden = [
  "@_cdecl",
  "dlopen",
  "dlsym",
  "nonisolated(unsafe)",
  "NWConnection",
  "NWBrowser",
  "URLSession",
  "Task {",
  "Timer(",
  "monitorIdentity",
]
forbidden.each do |token|
  violations << "Production lease source contains forbidden token: #{token}" if source.include?(token)
end

resolve = section(source, "  static func resolveRuntimeReference(", "  static func claim(")
require_order(
  resolve,
  [
    "let monitorKey = ProcessConnectionLeaseNamespace.monitorKey",
    "let candidate = NSObject()",
    "let enterStatus = runtime.enter(anchor)",
    "guard enterStatus == synchronizationSucceeded",
    "runtime.associatedObject(anchor, key: monitorKey)",
    "runtime.setAssociatedObject(",
    "let exitStatus = runtime.exit(anchor)",
    "withExtendedLifetime(candidate)",
    "guard exitStatus == synchronizationSucceeded",
    "return ProcessConnectionLeaseRuntimeReference(monitor: selectedMonitor)",
  ],
  "bootstrap",
  violations
)
reject_between(
  resolve,
  "static func resolveRuntimeReference(",
  "    var selectedMonitor",
  ["runtime.associatedObject(", "runtime.setAssociatedObject("],
  "bootstrap enter boundary",
  violations
)
reject_between(
  resolve,
  "    var selectedMonitor",
  "    let exitStatus = runtime.exit(anchor)",
  [
    "ProcessConnectionLeaseRuntimeReference(",
    "ProcessConnectionLeaseHandle(",
    "ProcessConnectionLeaseError",
    "withExtendedLifetime",
    "throw ",
    "return ",
  ],
  "bootstrap held-monitor region",
  violations
)

claim = section(source, "  static func claim(", "  static func release(")
require_order(
  claim,
  [
    "let ownerKey = ProcessConnectionLeaseNamespace.ownerKey",
    "let token = NSObject()",
    "let enterStatus = runtime.enter(monitor)",
    "guard enterStatus == synchronizationSucceeded",
    "runtime.associatedObject(",
    "runtime.setAssociatedObject(",
    "let exitStatus = runtime.exit(monitor)",
    "withExtendedLifetime(token)",
    "guard exitStatus == synchronizationSucceeded",
    "guard claimed",
    "return ProcessConnectionLeaseHandle(",
  ],
  "claim",
  violations
)
reject_between(
  claim,
  "static func claim(",
  "    let claimed: Bool",
  ["runtime.associatedObject(", "runtime.setAssociatedObject("],
  "claim enter boundary",
  violations
)
reject_between(
  claim,
  "    let claimed: Bool",
  "    let exitStatus = runtime.exit(monitor)",
  [
    "ProcessConnectionLeaseRuntimeReference(",
    "ProcessConnectionLeaseHandle(",
    "ProcessConnectionLeaseError",
    "withExtendedLifetime",
    "throw ",
    "return ",
  ],
  "claim held-monitor region",
  violations
)

if claim
  exit_index = claim.index("let exitStatus = runtime.exit(monitor)") || claim.length
  contention_index = claim.index("throw ProcessConnectionLeaseError.anotherConnectionIsActive")
  if contention_index && contention_index < exit_index
    violations << "Claim constructs its contention outcome before monitor exit."
  end
end

release = section(source, "  static func release(", "enum ProcessConnectionLeaseRegistry")
require_order(
  release,
  [
    "let ownerKey = ProcessConnectionLeaseNamespace.ownerKey",
    "let enterStatus = runtime.enter(monitor)",
    "guard enterStatus == synchronizationSucceeded",
    "runtime.associatedObject(",
    "runtime.setAssociatedObject(",
    "let exitStatus = runtime.exit(monitor)",
    "withExtendedLifetime(token)",
    "guard exitStatus == synchronizationSucceeded",
  ],
  "release",
  violations
)
reject_between(
  release,
  "static func release(",
  "    if let current",
  ["runtime.associatedObject(", "runtime.setAssociatedObject("],
  "release enter boundary",
  violations
)
reject_between(
  release,
  "    if let current",
  "    let exitStatus = runtime.exit(monitor)",
  [
    "ProcessConnectionLeaseRuntimeReference(",
    "ProcessConnectionLeaseHandle(",
    "ProcessConnectionLeaseError",
    "withExtendedLifetime",
    "throw ",
    "return ",
  ],
  "release held-monitor region",
  violations
)

error_definition = section(
  source,
  "struct ProcessConnectionLeaseError",
  "extension ProcessConnectionLeaseError"
)
require_order(
  error_definition,
  [
    "let code: Code",
    "var message: String",
    "switch code",
    "return \"Another NearWire connection is already active.\"",
    "return \"NearWire connection ownership is unavailable.\"",
    "private init(code: Code)",
  ],
  "closed error construction",
  violations
)
error_initializers = declaration_bodies(source, "ProcessConnectionLeaseError").flat_map do |body|
  body.scan(
    /(?:(?:public|internal|fileprivate|private)\s+)?init\s*\([^)]*\)/
  )
end
unless error_initializers == ["private init(code: Code)"]
  violations << "Process lease errors expose unexpected initializers: #{error_initializers.inspect}"
end
if error_definition&.include?("let message:")
  violations << "Process lease error message must be derived from its closed code."
end

if source.scan("ProcessConnectionLeaseNamespace.monitorKey").length != 1
  violations << "Bootstrap must resolve the monitor selector key exactly once before enter."
end
if source.scan("ProcessConnectionLeaseNamespace.ownerKey").length != 2
  violations << "Claim and release must each resolve the owner selector key once before enter."
end

registry = section(source, "enum ProcessConnectionLeaseRegistry", "\n}")
require_order(
  registry,
  [
    "private static let runtime = AppleProcessConnectionLeaseRuntime()",
    "private static let runtimeReference",
    "anchor: ProcessInfo.processInfo",
    "runtime: runtime",
    "static func claim()",
    "ProcessConnectionLeaseOperation.claim(reference: runtimeReference, runtime: runtime)",
  ],
  "production registry",
  violations
)

unless violations.empty?
  warn violations.join("\n")
  exit 1
end

puts "Process lease structural audit passed."
