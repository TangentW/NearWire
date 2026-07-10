#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

required_files=(
  "Package.swift"
  "NearWire.podspec"
  "NearWire.xcworkspace/contents.xcworkspacedata"
  "VERSION"
  "README.md"
  "CHANGELOG.md"
  "LICENSE"
  "AGENTS.md"
  "NearWire-Platform-Architecture.md"
)

required_directories=(
  "Core/Sources/NearWireCore"
  "Core/Sources/NearWireTransport"
  "Core/Sources/NearWireFlowControl"
  "Core/TestSupport/NearWireTestSupport"
  "Core/Tests"
  "SDK/Sources/NearWire"
  "SDK/Sources/NearWireUI"
  "SDK/Sources/NearWirePerformance"
  "SDK/Tests"
  "Viewer"
  "Demo"
  "IntegrationTests"
  "Documentation"
  "Scripts"
  "openspec/changes"
  "openspec/specs"
)

for path in "${required_files[@]}"; do
  if [[ ! -f "$path" ]]; then
    echo "Missing required file: $path" >&2
    exit 1
  fi
done

for path in "${required_directories[@]}"; do
  if [[ ! -d "$path" ]]; then
    echo "Missing required directory: $path" >&2
    exit 1
  fi
done

package_count="$(find . -name Package.swift -not -path './.build/*' -print | wc -l | tr -d ' ')"
podspec_count="$(find . -name '*.podspec' -not -path './Pods/*' -print | wc -l | tr -d ' ')"

if [[ "$package_count" != "1" ]]; then
  echo "Expected exactly one Package.swift, found $package_count." >&2
  exit 1
fi

if [[ "$podspec_count" != "1" ]]; then
  echo "Expected exactly one podspec, found $podspec_count." >&2
  exit 1
fi

if [[ -d "Examples" ]]; then
  echo "The maintained Demo must be in root Demo, not Examples." >&2
  exit 1
fi

while IFS= read -r script; do
  bash -n "$script"
  if [[ ! -x "$script" ]]; then
    echo "Validation script is not executable: $script" >&2
    exit 1
  fi
done < <(find Scripts -type f -name '*.sh' -print | sort)

while IFS= read -r script; do
  ruby -c "$script" >/dev/null
  if [[ ! -x "$script" ]]; then
    echo "Validation script is not executable: $script" >&2
    exit 1
  fi
done < <(find Scripts -type f -name '*.rb' -print | sort)

ruby -c NearWire.podspec >/dev/null
xmllint --noout NearWire.xcworkspace/contents.xcworkspacedata

echo "Repository structure verification passed."
