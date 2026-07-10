#!/usr/bin/env ruby

require "optparse"
require "open3"
require "pathname"

options = {
  core_root: "Core",
  sdk_root: "SDK/Sources"
}

OptionParser.new do |parser|
  parser.on("--core-root PATH") { |path| options[:core_root] = path }
  parser.on("--sdk-root PATH") { |path| options[:sdk_root] = path }
end.parse!

PLATFORM_UI_MODULES = %w[AppKit SwiftUI UIKit].freeze
INTERNAL_CORE_MODULES = %w[NearWireCore NearWireFlowControl NearWireTransport].freeze

def swift_files(root)
  path = Pathname.new(root)
  abort "Boundary root does not exist: #{root}" unless path.exist?

  path.directory? ? path.glob("**/*.swift").sort : [path]
end

def swift_identifier_tokens(source)
  tokens = []
  index = 0

  while index < source.length
    if source[index, 2] == "//"
      newline = source.index("\n", index + 2)
      index = newline || source.length
    elsif source[index, 2] == "/*"
      depth = 1
      index += 2
      while index < source.length && depth.positive?
        if source[index, 2] == "/*"
          depth += 1
          index += 2
        elsif source[index, 2] == "*/"
          depth -= 1
          index += 2
        else
          index += 1
        end
      end
    elsif source[index] == "#"
      hash_end = index
      hash_end += 1 while hash_end < source.length && source[hash_end] == "#"
      unless source[hash_end] == '"'
        index += 1
        next
      end

      hash_count = hash_end - index
      triple = source[hash_end, 3] == '"""'
      quote = triple ? '"""' : '"'
      terminator = "#{quote}#{"#" * hash_count}"
      index = hash_end + quote.length
      closing = source.index(terminator, index)
      index = closing ? closing + terminator.length : source.length
    elsif source[index] == '"'
      triple = source[index, 3] == '"""'
      index += triple ? 3 : 1
      terminator = triple ? '"""' : '"'
      while index < source.length
        if source[index] == "\\"
          index += 2
        elsif source[index, terminator.length] == terminator
          index += terminator.length
          break
        else
          index += 1
        end
      end
    elsif source[index].match?(/[A-Za-z_]/)
      ending = index + 1
      ending += 1 while ending < source.length && source[ending].match?(/[A-Za-z0-9_]/)
      tokens << source[index...ending]
      index = ending
    else
      index += 1
    end
  end

  tokens
end

def public_import?(path, line, column)
  lines = path.readlines
  prefix = lines.first(line - 1).join
  prefix += lines.fetch(line - 1)[0...(column - 1)]
  swift_identifier_tokens(prefix).last == "public"
end

def imports_in(root)
  swift_files(root).flat_map do |path|
    output, diagnostics, status = Open3.capture3(
      "xcrun",
      "swiftc",
      "-frontend",
      "-dump-parse",
      path.to_s
    )
    abort "Unable to parse #{path}: #{diagnostics}" unless status.success?

    output.lines.map do |line|
      next unless line.include?("(import_decl")

      module_match = line.match(/module="([^"]+)"/)
      next unless module_match

      location = line.match(/range=\[[^:]+:(\d+):(\d+)/)
      source_line = location&.[](1)
      source_column = location&.[](2)
      {
        path: path,
        line: source_line || "?",
        module_name: module_match[1].split(".").first,
        exported: line.match?(/\bexported\b/),
        public: location ? public_import?(path, source_line.to_i, source_column.to_i) : false,
      }
    end.compact
  end
end

violations = []

imports_in(options.fetch(:core_root)).each do |import|
  next unless PLATFORM_UI_MODULES.include?(import.fetch(:module_name))

  violations << "#{import.fetch(:path)}:#{import.fetch(:line)}: Core must not import #{import.fetch(:module_name)}"
end

imports_in(options.fetch(:sdk_root)).each do |import|
  next unless INTERNAL_CORE_MODULES.include?(import.fetch(:module_name))
  next unless import.fetch(:exported) || import.fetch(:public)

  violations << "#{import.fetch(:path)}:#{import.fetch(:line)}: SDK must not re-export #{import.fetch(:module_name)}"
end

unless violations.empty?
  warn violations.join("\n")
  exit 1
end

puts "Swift module import boundaries passed."
