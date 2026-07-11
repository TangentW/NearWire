#!/usr/bin/env ruby

require "optparse"
require "pathname"

options = { core_root: "Core/Sources" }
OptionParser.new do |parser|
  parser.on("--core-root PATH") { |path| options[:core_root] = path }
end.parse!

root = Pathname.new(options.fetch(:core_root))
abort "Core SPI root does not exist: #{root}" unless root.directory?

violations = []
root.glob("**/*.swift").sort.each do |path|
  previous_nonempty = nil
  path.readlines.each_with_index do |line, index|
    stripped = line.strip
    if line.start_with?("public ") && previous_nonempty != "@_spi(NearWireInternal)"
      violations << "#{path}:#{index + 1}: top-level public declaration lacks NearWireInternal SPI"
    end
    previous_nonempty = stripped unless stripped.empty?
  end
end

unless violations.empty?
  warn violations.join("\n")
  exit 1
end

puts "Core SPI visibility boundary passed."
