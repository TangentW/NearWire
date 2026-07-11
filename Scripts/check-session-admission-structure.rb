#!/usr/bin/env ruby

require "pathname"

root = Pathname.new(ARGV.fetch(0, ".")).expand_path
session_root = root.join("SDK/Sources/NearWire/Session")
files = %w[
  SDKSessionAdmission.swift
  SDKSessionAdmissionModels.swift
  SDKSessionChannelIngress.swift
  SDKSessionTransportCore.swift
].map { |name| session_root.join(name) }

missing = files.reject(&:file?)
abort "Missing session admission source: #{missing.join(", ")}" unless missing.empty?

source = files.map(&:read).join("\n")

required = {
  "exact discovery composition" => "ViewerDiscoveryCoordinator",
  "secure App transport factory" => "SecureAppTransport.makeChannel",
  "exact hello codec" => "WirePreHandshakeCodec",
  "negotiated session codec" => "WireSessionCodec",
  "continuous frame decoder" => "WireFrameDecoder",
  "discovery-to-hello discriminator binding" => "ViewerDiscoveryDiscriminator",
  "bounded callback ingress" => "SDKSessionChannelIngress",
  "permanent transport owner" => "SDKSessionTransportCore",
}

required.each do |description, token|
  abort "Session admission is missing #{description}." unless source.include?(token)
end

forbidden = {
  "process lease claim" => "ProcessConnectionLeaseRegistry",
  "supported state mutation" => "NearWireState",
  "event envelope transfer" => "EventEnvelope",
  "event payload transfer" => "WireEventPayload",
  "event batch transfer" => "WireEventBatchPayload",
  "SDK queue drain" => "BoundedEventQueue",
  "raw connection construction" => "NWConnection(",
}

forbidden.each do |description, token|
  abort "Session admission unexpectedly contains #{description}." if source.include?(token)
end

files.each do |file|
  file.each_line.with_index(1) do |line, line_number|
    next unless line.match?(/^\s*(?:@available\([^)]*\)\s*)?public\s+/)

    abort "#{file}:#{line_number}: session admission must remain implementation-only."
  end
end

puts "Session admission ownership and residual-scope boundaries passed."
