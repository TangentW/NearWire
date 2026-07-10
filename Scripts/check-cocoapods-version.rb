#!/usr/bin/env ruby

require "rubygems"

minimum = Gem::Version.new("1.16.0")

begin
  current = Gem::Version.new(ARGV.fetch(0))
rescue ArgumentError, IndexError => error
  warn "Unable to parse the CocoaPods version: #{error.message}"
  exit 1
end

if current < minimum
  warn "CocoaPods #{minimum} or later is required; found #{current}."
  exit 1
end

puts current
