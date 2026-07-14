#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

version="$(tr -d '[:space:]' < VERSION)"
ruby Scripts/validate-semver.rb "$version" >/dev/null

pod_version="$(pod ipc spec NearWire.podspec | ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("version")')"
if [[ "$pod_version" != "$version" ]]; then
  echo "Podspec version $pod_version does not match VERSION $version." >&2
  exit 1
fi

sdk_version="$(ruby -e '
  source = File.read("SDK/Sources/NearWire/Connection/SDKProductMetadata.swift")
  match = source.match(/static let current = "([^"]+)"/)
  abort "Compiled SDK version literal is unavailable." unless match
  puts match[1]
')"
if [[ "$sdk_version" != "$version" ]]; then
  echo "Compiled SDK version $sdk_version does not match VERSION $version." >&2
  exit 1
fi

ruby -e '
  expected = ARGV.shift
  ARGV.each do |path|
    source = File.read(path)
    versions = source.scan(/MARKETING_VERSION = ([^;]+);/).flatten.map(&:strip)
    abort "No MARKETING_VERSION values found in #{path}." if versions.empty?
    mismatches = versions.reject { |value| value == expected }
    unless mismatches.empty?
      abort "MARKETING_VERSION in #{path} does not match #{expected}: #{mismatches.uniq.join(", ")}"
    end
  end
' "$version" \
  Viewer/NearWireViewer.xcodeproj/project.pbxproj \
  Demo/NearWireDemo.xcodeproj/project.pbxproj

echo "Version verification passed for $version."
