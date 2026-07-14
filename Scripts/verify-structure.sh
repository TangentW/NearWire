#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

required_files=(
  "Package.swift"
  "NearWire.podspec"
  "NearWire.xcworkspace/contents.xcworkspacedata"
  "Demo/NearWireDemo.xcodeproj/project.pbxproj"
  "Demo/NearWireDemo.xcodeproj/xcshareddata/xcschemes/NearWireDemo.xcscheme"
  "Demo/NearWireDemo.xcodeproj/xcshareddata/xcschemes/NearWireDemoCocoaPods.xcscheme"
  "Demo/NearWireDemo/Resources/Info.plist"
  "Demo/Podfile"
  "VERSION"
  "README.md"
  "CHANGELOG.md"
  "LICENSE"
  "AGENTS.md"
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
ruby -c Demo/Podfile >/dev/null
plutil -lint Demo/NearWireDemo.xcodeproj/project.pbxproj >/dev/null
plutil -lint Demo/NearWireDemo/Resources/Info.plist >/dev/null
xmllint --noout NearWire.xcworkspace/contents.xcworkspacedata
xmllint --noout Demo/NearWireDemo.xcodeproj/xcshareddata/xcschemes/NearWireDemo.xcscheme
xmllint --noout Demo/NearWireDemo.xcodeproj/xcshareddata/xcschemes/NearWireDemoCocoaPods.xcscheme

for reference in \
  'group:Viewer/NearWireViewer.xcodeproj' \
  'group:Demo/NearWireDemo.xcodeproj'; do
  if ! rg -Fq "$reference" NearWire.xcworkspace/contents.xcworkspacedata; then
    echo "Missing root workspace reference: $reference" >&2
    exit 1
  fi
done

if ! rg -Fq 'relativePath = "..";' Demo/NearWireDemo.xcodeproj/project.pbxproj; then
  echo "Demo must use the repository-relative local package reference." >&2
  exit 1
fi

condition_count="$(rg -o 'NEARWIRE_DEMO_SEPARATE_MODULES' \
  Demo/NearWireDemo.xcodeproj/project.pbxproj | wc -l | tr -d ' ')"
if [[ "$condition_count" != "2" ]]; then
  echo "The SwiftPM-only Demo import condition must exist in exactly two build configurations." >&2
  exit 1
fi

for generated_path in Demo/Pods Demo/Podfile.lock Demo/NearWireDemo.xcworkspace; do
  if [[ -e "$generated_path" ]]; then
    echo "Generated CocoaPods state must not be committed: $generated_path" >&2
    exit 1
  fi
done

echo "Repository structure verification passed."
