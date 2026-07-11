#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

valid_versions=(
  "0.0.0"
  "1.0.0"
  "1.0.0-alpha"
  "1.0.0-alpha.1+build.5"
  "10.20.30+20260711"
)

invalid_versions=(
  "1"
  "1.0"
  "01.0.0"
  "1.01.0"
  "1.0.01"
  "1.0.0-01"
  "1.0.0-.."
  "1.0.0+"
  "v1.0.0"
)

for version in "${valid_versions[@]}"; do
  ruby Scripts/validate-semver.rb "$version" >/dev/null
done

for version in "${invalid_versions[@]}"; do
  if ruby Scripts/validate-semver.rb "$version" >/dev/null 2>&1; then
    echo "Expected invalid semantic version to fail: $version" >&2
    exit 1
  fi
done

ruby Scripts/check-cocoapods-version.rb "1.16.0" >/dev/null
ruby Scripts/check-cocoapods-version.rb "1.16.2" >/dev/null
ruby Scripts/check-cocoapods-version.rb "2.0.0.beta.1" >/dev/null

if ruby Scripts/check-cocoapods-version.rb "1.15.2" >/dev/null 2>&1; then
  echo "Expected CocoaPods 1.15.2 to fail the minimum-version check." >&2
  exit 1
fi

if ruby Scripts/check-cocoapods-version.rb "invalid" >/dev/null 2>&1; then
  echo "Expected an invalid CocoaPods version to fail parsing." >&2
  exit 1
fi

fixture_root="$(mktemp -d /tmp/nearwire-validation-tools.XXXXXX)"
trap 'rm -rf "$fixture_root"' EXIT

mkdir -p \
  "$fixture_root/Core/PackageTarget" \
  "$fixture_root/SDK" \
  "$fixture_root/Viewer"

printf '%s\n' '@_spi(NearWireInternal) public struct Fixture {}' > "$fixture_root/Core/Allowed.swift"
printf '%s\n' 'public struct Fixture {}' > "$fixture_root/SDK/Allowed.swift"
ruby Scripts/check-swift-boundaries.rb \
  --core-root "$fixture_root/Core" \
  --sdk-root "$fixture_root/SDK" \
  >/dev/null
ruby Scripts/check-core-spi-boundary.rb \
  --core-root "$fixture_root/Core" \
  >/dev/null
ruby Scripts/check-process-lease-structure.rb >/dev/null

lease_source="SDK/Sources/NearWire/Session/ProcessConnectionLease.swift"
lease_mutation_dir="$fixture_root/lease-mutations"
mkdir -p "$lease_mutation_dir"

ruby -e '
  source = File.read(ARGV.fetch(0))
  marker = "    guard enterStatus == synchronizationSucceeded else {"
  source.sub!(marker, "    _ = runtime.associatedObject(anchor, key: monitorKey)\n#{marker}")
  File.write(ARGV.fetch(1), source)
' "$lease_source" "$lease_mutation_dir/pre-enter-access.swift"

ruby -e '
  source = File.read(ARGV.fetch(0))
  marker = "    let claimed: Bool"
  source.sub!(marker, "#{marker}\n    _ = ProcessConnectionLeaseError.runtimeUnavailable")
  File.write(ARGV.fetch(1), source)
' "$lease_source" "$lease_mutation_dir/pre-exit-outcome.swift"

ruby -e '
  source = File.read(ARGV.fetch(0))
  marker = "    let exitStatus = runtime.exit(monitor)"
  source.sub!(marker, "    withExtendedLifetime(token) {}\n#{marker}")
  File.write(ARGV.fetch(1), source)
' "$lease_source" "$lease_mutation_dir/pre-exit-cleanup.swift"

ruby -e '
  source = File.read(ARGV.fetch(0))
  marker = "  private init(code: Code) {"
  arbitrary = <<~SWIFT
      init(code: Code, diagnostic: String) {
        self.code = code
        message = diagnostic
      }

  SWIFT
  source.sub!(marker, "#{arbitrary}#{marker}")
  File.write(ARGV.fetch(1), source)
' "$lease_source" "$lease_mutation_dir/arbitrary-error-message.swift"

ruby -e '
  source = File.read(ARGV.fetch(0))
  arbitrary = <<~SWIFT

    extension ProcessConnectionLeaseError {
      init(code: Code, diagnostic: String) {
        self.code = code
      }
    }
  SWIFT
  File.write(ARGV.fetch(1), "#{source}#{arbitrary}")
' "$lease_source" "$lease_mutation_dir/extension-error-initializer.swift"

for mutation in "$lease_mutation_dir"/*.swift; do
  if ruby Scripts/check-process-lease-structure.rb "$mutation" >/dev/null 2>&1; then
    echo "Expected process lease structural mutation to fail: $mutation" >&2
    exit 1
  fi
done

printf '%s\n' 'public struct LeakedCoreType {}' > "$fixture_root/Core/Violation.swift"
if ruby Scripts/check-core-spi-boundary.rb \
  --core-root "$fixture_root/Core" \
  >/dev/null 2>&1; then
  echo "Expected a Core declaration without SPI to fail." >&2
  exit 1
fi
rm "$fixture_root/Core/Violation.swift"

printf '%s\n' '@_spi(NearWireInternal)' 'public struct MultilineSPIFixture {}' \
  > "$fixture_root/Core/MultilineSPI.swift"
ruby Scripts/check-core-spi-boundary.rb \
  --core-root "$fixture_root/Core" \
  >/dev/null
rm "$fixture_root/Core/MultilineSPI.swift"

swift_import_violations=(
  '@_implementationOnly import UIKit'
  '@preconcurrency import SwiftUI'
  'public import AppKit'
  'import class UIKit.UIView'
  '/* platform import */ import UIKit'
)

for violation in "${swift_import_violations[@]}"; do
  printf '%s\n' "$violation" > "$fixture_root/Core/Violation.swift"
  if ruby Scripts/check-swift-boundaries.rb \
    --core-root "$fixture_root/Core" \
    --sdk-root "$fixture_root/SDK" \
    >/dev/null 2>&1; then
    echo "Expected Swift boundary violation to fail: $violation" >&2
    exit 1
  fi
done
rm "$fixture_root/Core/Violation.swift"

printf '%s\n' '/*' 'import UIKit' '*/' 'public struct CommentFixture {}' \
  > "$fixture_root/Core/CommentOnly.swift"
ruby Scripts/check-swift-boundaries.rb \
  --core-root "$fixture_root/Core" \
  --sdk-root "$fixture_root/SDK" \
  >/dev/null
rm "$fixture_root/Core/CommentOnly.swift"

printf '%s\n' '@_exported import NearWireCore' > "$fixture_root/SDK/Violation.swift"
if ruby Scripts/check-swift-boundaries.rb \
  --core-root "$fixture_root/Core" \
  --sdk-root "$fixture_root/SDK" \
  >/dev/null 2>&1; then
  echo "Expected an internal Core re-export to fail." >&2
  exit 1
fi
rm "$fixture_root/SDK/Violation.swift"

printf '%s\n' '@_exported' 'import NearWireCore' > "$fixture_root/SDK/Violation.swift"
if ruby Scripts/check-swift-boundaries.rb \
  --core-root "$fixture_root/Core" \
  --sdk-root "$fixture_root/SDK" \
  >/dev/null 2>&1; then
  echo "Expected a multiline internal Core re-export to fail." >&2
  exit 1
fi
rm "$fixture_root/SDK/Violation.swift"

printf '%s\n' 'public import NearWireCore' > "$fixture_root/SDK/Violation.swift"
if ruby Scripts/check-swift-boundaries.rb \
  --core-root "$fixture_root/Core" \
  --sdk-root "$fixture_root/SDK" \
  >/dev/null 2>&1; then
  echo "Expected a public internal Core import to fail." >&2
  exit 1
fi
rm "$fixture_root/SDK/Violation.swift"

printf '%s\n' 'public' 'import NearWireCore' > "$fixture_root/SDK/Violation.swift"
if ruby Scripts/check-swift-boundaries.rb \
  --core-root "$fixture_root/Core" \
  --sdk-root "$fixture_root/SDK" \
  >/dev/null 2>&1; then
  echo "Expected a multiline public internal Core import to fail." >&2
  exit 1
fi
rm "$fixture_root/SDK/Violation.swift"

valid_package_json='{"dependencies":[],"targets":[{"name":"Core","type":"regular","path":"Core/PackageTarget","dependencies":[]}]}'
printf '%s' "$valid_package_json" | ruby Scripts/check-package-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null

package_path_violation='{"dependencies":[],"targets":[{"name":"Escape","type":"regular","path":"Core/../Viewer/Escape","dependencies":[]}]}'
if printf '%s' "$package_path_violation" | ruby Scripts/check-package-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected a Swift Package target path traversal to fail." >&2
  exit 1
fi

ln -s "$fixture_root/Viewer" "$fixture_root/Core/LinkedViewer"
package_symlink_violation='{"dependencies":[],"targets":[{"name":"Escape","type":"regular","path":"Core/LinkedViewer","dependencies":[]}]}'
if printf '%s' "$package_symlink_violation" | ruby Scripts/check-package-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected a Swift Package symlink escape to fail." >&2
  exit 1
fi
rm "$fixture_root/Core/LinkedViewer"

implicit_package_target='{"dependencies":[],"targets":[{"name":"Implicit","type":"regular","path":null,"dependencies":[]}]}'
if printf '%s' "$implicit_package_target" | ruby Scripts/check-package-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected an implicit Swift Package target path to fail." >&2
  exit 1
fi

remote_binary_target='{"dependencies":[],"targets":[{"name":"RemoteBinary","type":"binary","path":null,"url":"https://example.invalid/binary.zip","checksum":"placeholder","dependencies":[]}]}'
if printf '%s' "$remote_binary_target" | ruby Scripts/check-package-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected a remote binary Swift Package target to fail." >&2
  exit 1
fi

root_symlink_fixture="$fixture_root/root-symlink"
mkdir -p \
  "$root_symlink_fixture/Viewer/PackageTarget" \
  "$root_symlink_fixture/SDK"
ln -s "$root_symlink_fixture/Viewer" "$root_symlink_fixture/Core"
if printf '%s' "$valid_package_json" | ruby Scripts/check-package-boundaries.rb \
  --root "$root_symlink_fixture" \
  >/dev/null 2>&1; then
  echo "Expected a symlinked Swift Package ownership root to fail." >&2
  exit 1
fi

valid_podspec_json='{"name":"NearWire","pod_target_xcconfig":{"DEFINES_MODULE":"YES","SWIFT_STRICT_CONCURRENCY":"complete","SWIFT_TREAT_WARNINGS_AS_ERRORS":"YES"},"subspecs":[{"name":"NearWire/Core","source_files":["Core/**/*.swift"]},{"name":"NearWire/SDK","dependencies":{"NearWire/Core":[]},"source_files":["SDK/**/*.swift"]}]}'
printf '%s' "$valid_podspec_json" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null

printf '%s\n' 'func compilePublicAPI() {}' > "$fixture_root/SDK/PublicAPI.swift"
valid_pod_testspec_json='{"name":"NearWire","testspecs":[{"name":"PublicAPI","test_type":"unit","source_files":["SDK/PublicAPI.swift"]}]}'
printf '%s' "$valid_pod_testspec_json" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null

invalid_pod_testspec_json='{"name":"NearWire","testspecs":[{"name":"ArbitraryTests","test_type":"unit","source_files":["SDK/PublicAPI.swift"]}]}'
if printf '%s' "$invalid_pod_testspec_json" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected an unauthorized CocoaPods test specification to fail." >&2
  exit 1
fi

root_dependency_violation='{"name":"NearWire","dependencies":{"ExternalKit":[]}}'
if printf '%s' "$root_dependency_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected a root podspec external dependency to fail." >&2
  exit 1
fi

subspec_dependency_violation='{"name":"NearWire","subspecs":[{"name":"NearWire/SDK","dependencies":{"ExternalKit":[]},"source_files":["SDK/Sources/**/*.swift"]}]}'
if printf '%s' "$subspec_dependency_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected a podspec subspec external dependency to fail." >&2
  exit 1
fi

platform_dependency_violation='{"name":"NearWire","subspecs":[{"name":"NearWire/SDK","ios":{"dependencies":{"ExternalKit":[]}}}]}'
if printf '%s' "$platform_dependency_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected a platform-specific external pod dependency to fail." >&2
  exit 1
fi

platform_source_violation='{"name":"NearWire","subspecs":[{"name":"NearWire/SDK","ios":{"source_files":["Viewer/**/*.swift"]}}]}'
if printf '%s' "$platform_source_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected a platform-specific unauthorized source path to fail." >&2
  exit 1
fi

pod_path_violation='{"name":"NearWire","subspecs":[{"name":"NearWire/Core","source_files":["Core/../Viewer/**/*.swift"]}]}'
if printf '%s' "$pod_path_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected a podspec source path traversal to fail." >&2
  exit 1
fi

pod_brace_violation='{"name":"NearWire","subspecs":[{"name":"NearWire/Core","source_files":["Core/{PackageTarget,../Viewer}/**/*.swift"]}]}'
if printf '%s' "$pod_brace_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected a brace-expanded podspec traversal to fail." >&2
  exit 1
fi

printf '%s\n' 'internal struct Secret {}' > "$fixture_root/Viewer/Secret.swift"
ln -s "$fixture_root/Viewer/Secret.swift" "$fixture_root/Core/LinkedSecret.swift"
pod_symlink_violation='{"name":"NearWire","subspecs":[{"name":"NearWire/Core","source_files":["Core/LinkedSecret.swift"]}]}'
if printf '%s' "$pod_symlink_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected a podspec source symlink escape to fail." >&2
  exit 1
fi
rm "$fixture_root/Core/LinkedSecret.swift"

if printf '%s' "$valid_podspec_json" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$root_symlink_fixture" \
  >/dev/null 2>&1; then
  echo "Expected a symlinked CocoaPods ownership root to fail." >&2
  exit 1
fi

root_vendor_violation='{"name":"NearWire","vendored_frameworks":["Core/Binary.xcframework"]}'
if printf '%s' "$root_vendor_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected a root vendored framework to fail." >&2
  exit 1
fi

subspec_vendor_violation='{"name":"NearWire","subspecs":[{"name":"NearWire/SDK","vendored_libraries":["SDK/libExternal.a"]}]}'
if printf '%s' "$subspec_vendor_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected a subspec vendored library to fail." >&2
  exit 1
fi

platform_vendor_violation='{"name":"NearWire","subspecs":[{"name":"NearWire/SDK","ios":{"vendored_frameworks":["SDK/Binary.xcframework"]}}]}'
if printf '%s' "$platform_vendor_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected a platform-specific vendored framework to fail." >&2
  exit 1
fi

prepare_command_violation='{"name":"NearWire","prepare_command":"curl https://example.invalid/script"}'
if printf '%s' "$prepare_command_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected a CocoaPods prepare command to fail." >&2
  exit 1
fi

script_phase_violation='{"name":"NearWire","subspecs":[{"name":"NearWire/SDK","script_phases":[{"name":"Run","script":"true"}]}]}'
if printf '%s' "$script_phase_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected a CocoaPods script phase to fail." >&2
  exit 1
fi

module_map_violation='{"name":"NearWire","subspecs":[{"name":"NearWire/Core","module_map":"Viewer/module.modulemap"}]}'
if printf '%s' "$module_map_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected a custom CocoaPods module map to fail." >&2
  exit 1
fi

platform_prefix_header_violation='{"name":"NearWire","subspecs":[{"name":"NearWire/SDK","ios":{"prefix_header_file":"Viewer/Prefix.pch"}}]}'
if printf '%s' "$platform_prefix_header_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected a platform-specific prefix header to fail." >&2
  exit 1
fi

project_header_violation='{"name":"NearWire","subspecs":[{"name":"NearWire/Core","project_header_files":["Viewer/**/*.h"]}]}'
if printf '%s' "$project_header_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected an unauthorized project header path to fail." >&2
  exit 1
fi

on_demand_resource_violation='{"name":"NearWire","subspecs":[{"name":"NearWire/SDK","on_demand_resources":{"Assets":["SDK/Assets/**"]}}]}'
if printf '%s' "$on_demand_resource_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected unsupported on-demand resources to fail." >&2
  exit 1
fi

testspec_violation='{"name":"NearWire","testspecs":[{"name":"Tests","source_files":["Viewer/**/*.swift"]}]}'
if printf '%s' "$testspec_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected a CocoaPods test specification to fail." >&2
  exit 1
fi

appspec_violation='{"name":"NearWire","appspecs":[{"name":"App","source_files":["Viewer/**/*.swift"]}]}'
if printf '%s' "$appspec_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected a CocoaPods app specification to fail." >&2
  exit 1
fi

user_xcconfig_violation='{"name":"NearWire","user_target_xcconfig":{"OTHER_LDFLAGS":"-force_load external.a"}}'
if printf '%s' "$user_xcconfig_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected consumer xcconfig injection to fail." >&2
  exit 1
fi

compiler_flags_violation='{"name":"NearWire","subspecs":[{"name":"NearWire/SDK","compiler_flags":"-load-plugin-executable external"}]}'
if printf '%s' "$compiler_flags_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected custom compiler flags to fail." >&2
  exit 1
fi

pod_xcconfig_violation='{"name":"NearWire","subspecs":[{"name":"NearWire/SDK","ios":{"pod_target_xcconfig":{"OTHER_SWIFT_FLAGS":"-load-plugin-executable external"}}}]}'
if printf '%s' "$pod_xcconfig_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected unsupported pod target xcconfig injection to fail." >&2
  exit 1
fi

legacy_xcconfig_violation='{"name":"NearWire","xcconfig":{"OTHER_SWIFT_FLAGS":"-DATTACK"}}'
if printf '%s' "$legacy_xcconfig_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected legacy CocoaPods xcconfig injection to fail." >&2
  exit 1
fi

subspec_legacy_xcconfig_violation='{"name":"NearWire","subspecs":[{"name":"NearWire/SDK","xcconfig":{"OTHER_SWIFT_FLAGS":"-DATTACK"}}]}'
if printf '%s' "$subspec_legacy_xcconfig_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected subspec legacy CocoaPods xcconfig injection to fail." >&2
  exit 1
fi

platform_legacy_xcconfig_violation='{"name":"NearWire","subspecs":[{"name":"NearWire/SDK","ios":{"xcconfig":{"OTHER_SWIFT_FLAGS":"-DATTACK"}}}]}'
if printf '%s' "$platform_legacy_xcconfig_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected platform legacy CocoaPods xcconfig injection to fail." >&2
  exit 1
fi

linkage_violation='{"name":"NearWire","static_framework":true}'
if printf '%s' "$linkage_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected a forced pod linkage mode to fail." >&2
  exit 1
fi

framework_violation='{"name":"NearWire","frameworks":["ExternalFramework"]}'
if printf '%s' "$framework_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected an undeclared framework linkage to fail." >&2
  exit 1
fi

weak_framework_violation='{"name":"NearWire","subspecs":[{"name":"NearWire/SDK","weak_frameworks":["ExternalFramework"]}]}'
if printf '%s' "$weak_framework_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected an undeclared weak framework linkage to fail." >&2
  exit 1
fi

library_violation='{"name":"NearWire","subspecs":[{"name":"NearWire/SDK","ios":{"libraries":["external"]}}]}'
if printf '%s' "$library_violation" | ruby Scripts/check-podspec-boundaries.rb \
  --root "$fixture_root" \
  >/dev/null 2>&1; then
  echo "Expected an undeclared library linkage to fail." >&2
  exit 1
fi

root_parity_json="$fixture_root/root-parity.json"
core_parity_json="$fixture_root/core-parity.json"
printf '%s' '{"targets":[{"name":"Core","type":"regular","path":"Core/Sources/Core","dependencies":[]}]}' \
  > "$root_parity_json"
printf '%s' '{"targets":[{"name":"Core","type":"regular","path":"Core/Sources/Core","dependencies":[]}]}' \
  > "$core_parity_json"
ruby Scripts/check-core-package-parity.rb "$root_parity_json" "$core_parity_json" >/dev/null

printf '%s' '{"targets":[]}' > "$core_parity_json"
if ruby Scripts/check-core-package-parity.rb \
  "$root_parity_json" \
  "$core_parity_json" \
  >/dev/null 2>&1; then
  echo "Expected a drifted Core package fixture to fail parity validation." >&2
  exit 1
fi

printf '%s' '{"targets":[{"name":"Core","type":"regular","path":"Core/Sources/Core","dependencies":[],"settings":[{"unsafeFlags":["-Xfrontend","-warn-concurrency"]}]}]}' \
  > "$root_parity_json"
printf '%s' '{"targets":[{"name":"Core","type":"regular","path":"Core/Sources/Core","dependencies":[],"settings":[{"unsafeFlags":["-warn-concurrency","-Xfrontend"]}]}]}' \
  > "$core_parity_json"
if ruby Scripts/check-core-package-parity.rb \
  "$root_parity_json" \
  "$core_parity_json" \
  >/dev/null 2>&1; then
  echo "Expected ordered compiler flag drift to fail Core package parity." >&2
  exit 1
fi

printf '%s' '{"targets":[{"name":"Core","type":"regular","path":"Core/Sources/Core","dependencies":[{"byName":["Dependency",{"platformNames":["ios"]}]}]}]}' \
  > "$root_parity_json"
printf '%s' '{"targets":[{"name":"Core","type":"regular","path":"Core/Sources/Core","dependencies":[{"byName":["Dependency",null]}]}]}' \
  > "$core_parity_json"
if ruby Scripts/check-core-package-parity.rb \
  "$root_parity_json" \
  "$core_parity_json" \
  >/dev/null 2>&1; then
  echo "Expected conditional dependency drift to fail Core package parity." >&2
  exit 1
fi

./Scripts/Tests/evidence-capture.sh
./Scripts/Tests/simulator-state.sh
ruby Scripts/check-distribution-contract.rb --self-test

echo "Validation tool tests passed."
