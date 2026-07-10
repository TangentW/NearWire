#!/usr/bin/env ruby

require "json"
require "pathname"

abort "Usage: check-core-package-parity.rb ROOT_JSON CORE_JSON" unless ARGV.length == 2

root_package = JSON.parse(File.read(ARGV.fetch(0)))
core_package = JSON.parse(File.read(ARGV.fetch(1)))

def canonicalize(value)
  case value
  when Hash
    value.keys.sort.each_with_object({}) do |key, result|
      result[key] = canonicalize(value.fetch(key))
    end
  when Array
    value.map { |entry| canonicalize(entry) }
  else
    value
  end
end

def normalized_target(target)
  normalized = target.dup
  normalized["path"] = Pathname.new(target.fetch("path")).cleanpath.to_s
  canonicalize(normalized)
end

root_targets = root_package.fetch("targets").select do |target|
  path = target["path"]
  path && Pathname.new(path).cleanpath.to_s.start_with?("Core/")
end.map { |target| normalized_target(target) }.sort_by { |target| target.fetch("name") }

fixture_targets = core_package.fetch("targets").map do |target|
  normalized_target(target)
end.sort_by { |target| target.fetch("name") }

unless root_targets == fixture_targets
  warn "Core package fixture does not match the root package Core graph."
  warn "Root: #{JSON.pretty_generate(root_targets)}"
  warn "Fixture: #{JSON.pretty_generate(fixture_targets)}"
  exit 1
end

puts "Core package fixture parity passed."
