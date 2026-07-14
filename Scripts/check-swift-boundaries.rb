#!/usr/bin/env ruby

require "optparse"
require "pathname"

options = {
  core_root: "Core",
  sdk_root: "SDK/Sources",
  demo_root: "Demo/NearWireDemo"
}

OptionParser.new do |parser|
  parser.on("--core-root PATH") { |path| options[:core_root] = path }
  parser.on("--sdk-root PATH") { |path| options[:sdk_root] = path }
  parser.on("--demo-root PATH") { |path| options[:demo_root] = path }
end.parse!

PLATFORM_UI_MODULES = %w[AppKit SwiftUI UIKit].freeze
INTERNAL_CORE_MODULES = %w[NearWireCore NearWireFlowControl NearWireTransport].freeze
DEMO_MODULES = %w[Foundation NearWire NearWirePerformance NearWireUI SwiftUI].freeze

def swift_files(root)
  path = Pathname.new(root)
  abort "Boundary root does not exist: #{root}" unless path.exist?

  path.directory? ? path.glob("**/*.swift").sort : [path]
end

def swift_identifier_tokens(source)
  tokens = []
  index = 0
  line = 1

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
          line += 1 if source[index] == "\n"
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
      line += source[index...(closing || source.length)].count("\n")
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
          line += 1 if source[index] == "\n"
          index += 1
        end
      end
    elsif source[index].match?(/[A-Za-z_]/)
      ending = index + 1
      ending += 1 while ending < source.length && source[ending].match?(/[A-Za-z0-9_]/)
      tokens << { value: source[index...ending], line: line }
      index = ending
    else
      line += 1 if source[index] == "\n"
      index += 1
    end
  end

  tokens
end

def imports_in(root)
  swift_files(root).flat_map do |path|
    tokens = swift_identifier_tokens(path.read)
    tokens.each_index.each_with_object([]) do |index, imports|
      token = tokens.fetch(index)
      next unless token.fetch(:value) == "import"

      module_index = index + 1
      if %w[class enum func let protocol struct typealias var].include?(
        tokens.fetch(module_index, {}).fetch(:value, nil)
      )
        module_index += 1
      end
      module_token = tokens[module_index]
      next unless module_token

      modifiers = tokens[[index - 4, 0].max...index].map { |value| value.fetch(:value) }
      imports << {
        path: path,
        line: token.fetch(:line),
        module_name: module_token.fetch(:value),
        exported: modifiers.include?("_exported"),
        public: modifiers.last == "public",
      }
    end
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

imports_in(options.fetch(:demo_root)).each do |import|
  next if DEMO_MODULES.include?(import.fetch(:module_name))

  violations << "#{import.fetch(:path)}:#{import.fetch(:line)}: Demo must not import #{import.fetch(:module_name)}"
end

unless violations.empty?
  warn violations.join("\n")
  exit 1
end

puts "Swift module import boundaries passed."
