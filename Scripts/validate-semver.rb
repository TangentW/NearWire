#!/usr/bin/env ruby

SEMVER_PATTERN = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?\z/

version = ARGV.fetch(0, "")

unless SEMVER_PATTERN.match?(version)
  warn "Invalid Semantic Version 2.0.0 value: #{version.inspect}"
  exit 1
end

puts version
