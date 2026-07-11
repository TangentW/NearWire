#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/Scripts/lib/simulator-state.sh"

export HOME="${NEARWIRE_BUILD_HOME:-$ROOT/.build/home}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$ROOT/.build/cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/ModuleCache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT/.build/ModuleCache}"

mkdir -p \
  "$HOME" \
  "$XDG_CACHE_HOME" \
  "$CLANG_MODULE_CACHE_PATH" \
  "$ROOT/.build/config" \
  "$ROOT/.build/security"

swift_cache_options=(
  --cache-path "$ROOT/.build/cache"
  --config-path "$ROOT/.build/config"
  --security-path "$ROOT/.build/security"
  --manifest-cache local
  --disable-dependency-cache
  --disable-build-manifest-caching
)

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required." >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "swift is required." >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun is required." >&2
  exit 1
fi

swift format lint --recursive \
  Package.swift \
  Core \
  SDK \
  Scripts/Fixtures/CorePackage.swift \
  Scripts/Fixtures/SecureTransportPublicAPI.swift \
  Scripts/Fixtures/ForbiddenPlaintextTransport.swift \
  Scripts/Fixtures/ForbiddenRawSecureChannel.swift \
  Scripts/Fixtures/ForbiddenSameModuleRawSecureChannel.swift \
  Scripts/Fixtures/WirePublicAPI.swift \
  Scripts/Fixtures/ForbiddenWirePayload.swift

xcode_version="$(xcodebuild -version)"
xcode_major="$(awk '/Xcode/ { split($2, parts, "."); print parts[1]; exit }' <<< "$xcode_version")"
if [[ -z "$xcode_major" || "$xcode_major" -lt 16 ]]; then
  echo "Xcode 16 or later is required." >&2
  exit 1
fi

strict_concurrency_options=(
  -Xswiftc -strict-concurrency=complete
  -Xswiftc -warnings-as-errors
)

swift package "${swift_cache_options[@]}" --disable-sandbox resolve
swift package "${swift_cache_options[@]}" --disable-sandbox describe >/dev/null
package_json="$(swift package "${swift_cache_options[@]}" --disable-sandbox dump-package)"

package_harness="$(mktemp -d /tmp/nearwire-package-harness.XXXXXX)"
simulator_id=""
simulator_initial_state=""

cleanup() {
  local status=$?
  local final_status
  trap - EXIT

  set +e
  nearwire_restore_simulator_state \
    "$simulator_initial_state" \
    "$simulator_id" \
    "$status"
  final_status=$?
  set -e

  rm -rf "$package_harness"
  exit "$final_status"
}

trap cleanup EXIT

cp Package.swift "$package_harness/Package.swift"
ln -s "$ROOT/Core" "$package_harness/Core"
ln -s "$ROOT/SDK" "$package_harness/SDK"

core_harness="$package_harness/CoreHarness"
mkdir -p "$core_harness"
cp Scripts/Fixtures/CorePackage.swift "$core_harness/Package.swift"
ln -s "$ROOT/Core" "$core_harness/Core"
ln -s "$ROOT/IntegrationTests" "$core_harness/IntegrationTests"

if [[ ! -f "$core_harness/IntegrationTests/Fixtures/Protocol/v1/hello.json" ]]; then
  echo "Core harness protocol fixtures are unavailable." >&2
  exit 1
fi

core_package_json="$(swift package \
  --package-path "$core_harness" \
  "${swift_cache_options[@]}" \
  --disable-sandbox \
  dump-package)"

root_package_json_path="$package_harness/root-package.json"
core_package_json_path="$package_harness/core-package.json"
printf '%s' "$package_json" > "$root_package_json_path"
printf '%s' "$core_package_json" > "$core_package_json_path"
ruby Scripts/check-core-package-parity.rb \
  "$root_package_json_path" \
  "$core_package_json_path"

ios_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
swift build \
  "${swift_cache_options[@]}" \
  --disable-sandbox \
  --scratch-path "$ROOT/.build/ios16" \
  --triple arm64-apple-ios16.0 \
  --sdk "$ios_sdk" \
  "${strict_concurrency_options[@]}"

macos_sdk="$(xcrun --sdk macosx --show-sdk-path)"
core_build_targets=()
while IFS= read -r target; do
  core_build_targets+=("$target")
done < <(printf '%s' "$package_json" | ruby -rjson -e '
  package = JSON.parse(STDIN.read)
  package.fetch("targets").each do |target|
    path = target["path"]
    next unless target["type"] == "regular" && path&.start_with?("Core/")
    puts target.fetch("name")
  end
')

if [[ "${#core_build_targets[@]}" -eq 0 ]]; then
  echo "No macOS Core build targets were found in Package.swift." >&2
  exit 1
fi

for target in "${core_build_targets[@]}"; do
  swift build \
    "${swift_cache_options[@]}" \
    --disable-sandbox \
    --scratch-path "$ROOT/.build/macos13" \
    --triple arm64-apple-macosx13.0 \
    --sdk "$macos_sdk" \
    --target "$target" \
    "${strict_concurrency_options[@]}"
done

macos_module_path="$ROOT/.build/macos13/arm64-apple-macosx/debug/Modules"
if [[ ! -d "$macos_module_path" ]]; then
  echo "macOS Core module output is unavailable for public API boundary checks." >&2
  exit 1
fi

xcrun swiftc \
  -typecheck \
  -I "$macos_module_path" \
  Scripts/Fixtures/WirePublicAPI.swift

forbidden_wire_diagnostics="$package_harness/forbidden-wire-payload.log"
if xcrun swiftc \
  -typecheck \
  -I "$macos_module_path" \
  Scripts/Fixtures/ForbiddenWirePayload.swift \
  >"$forbidden_wire_diagnostics" 2>&1; then
  echo "External code unexpectedly conformed to the sealed wire payload protocol." >&2
  exit 1
fi
if ! grep -Fq "cannot find type 'WireMessagePayload' in scope" \
  "$forbidden_wire_diagnostics"; then
  echo "Sealed wire payload boundary failed for an unexpected compiler reason." >&2
  cat "$forbidden_wire_diagnostics" >&2
  exit 1
fi

echo "Wire payload public API sealing passed."

xcrun swiftc \
  -typecheck \
  -I "$macos_module_path" \
  Scripts/Fixtures/SecureTransportPublicAPI.swift

forbidden_plaintext_diagnostics="$package_harness/forbidden-plaintext-transport.log"
if xcrun swiftc \
  -typecheck \
  -I "$macos_module_path" \
  Scripts/Fixtures/ForbiddenPlaintextTransport.swift \
  >"$forbidden_plaintext_diagnostics" 2>&1; then
  echo "External code unexpectedly constructed supported plaintext transport." >&2
  exit 1
fi
if ! grep -Fq "cannot find 'SecureNetworkParameters' in scope" \
  "$forbidden_plaintext_diagnostics"; then
  echo "Plaintext transport boundary failed for an unexpected compiler reason." >&2
  cat "$forbidden_plaintext_diagnostics" >&2
  exit 1
fi

echo "Mandatory TLS public API boundary passed."

forbidden_raw_channel_diagnostics="$package_harness/forbidden-raw-secure-channel.log"
if xcrun swiftc \
  -typecheck \
  -I "$macos_module_path" \
  Scripts/Fixtures/ForbiddenRawSecureChannel.swift \
  >"$forbidden_raw_channel_diagnostics" 2>&1; then
  echo "External code unexpectedly wrapped a plaintext connection in a secure channel." >&2
  exit 1
fi
if ! grep -Fq "initializer is inaccessible due to 'fileprivate' protection level" \
  "$forbidden_raw_channel_diagnostics"; then
  echo "Raw secure-channel boundary failed for an unexpected compiler reason." >&2
  cat "$forbidden_raw_channel_diagnostics" >&2
  exit 1
fi

echo "Raw connection wrapping boundary passed."

same_module_sources=()
while IFS= read -r source; do
  same_module_sources+=("$source")
done < <(find Core/Sources -type f -name '*.swift' -print | sort)
forbidden_same_module_diagnostics="$package_harness/forbidden-same-module-channel.log"
if xcrun swiftc \
  -typecheck \
  -module-name NearWire \
  "${same_module_sources[@]}" \
  Scripts/Fixtures/ForbiddenSameModuleRawSecureChannel.swift \
  >"$forbidden_same_module_diagnostics" 2>&1; then
  echo "A CocoaPods-style same module unexpectedly wrapped a plaintext connection." >&2
  exit 1
fi
if ! grep -Fq "argument type 'NWConnection' does not conform to expected type 'SecureConnectionDriving'" \
  "$forbidden_same_module_diagnostics"; then
  echo "Same-module raw channel boundary failed for an unexpected compiler reason." >&2
  cat "$forbidden_same_module_diagnostics" >&2
  exit 1
fi

echo "CocoaPods same-module raw connection boundary passed."

if rg -n \
  'SecItem(Add|Update|Delete)|SecKeyCreateRandom|SecItemExport|SecItemImport' \
  Core/Sources/NearWireTransport; then
  echo "Transport production code unexpectedly manages certificate or key lifecycle." >&2
  exit 1
fi

echo "Transport identity lifecycle boundary passed."

read -r simulator_id simulator_initial_state <<< "$(xcrun simctl list devices available -j | ruby -rjson -e '
  data = JSON.parse(STDIN.read)
  devices = data.fetch("devices").values.flatten
  phone = devices.find do |device|
    device.fetch("isAvailable", false) && device.fetch("name", "").start_with?("iPhone")
  end
  abort "No available iPhone Simulator was found." unless phone
  puts "#{phone.fetch("udid")} #{phone.fetch("state")}"
')"

if [[ "$simulator_initial_state" != "Booted" ]]; then
  xcrun simctl boot "$simulator_id"
fi
xcrun simctl bootstatus "$simulator_id" -b >/dev/null

ios_result_bundle="$package_harness/NearWire-iOS.xcresult"

(
  cd "$package_harness"

  xcodebuild \
    -quiet \
    -scheme NearWire-Package \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -derivedDataPath "$package_harness/DerivedData-iOS" \
    -resultBundlePath "$ios_result_bundle" \
    IPHONEOS_DEPLOYMENT_TARGET=16.0 \
    SWIFT_VERSION=5.0 \
    SWIFT_STRICT_CONCURRENCY=complete \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    test

)

xcrun xcresulttool get test-results summary --path "$ios_result_bundle"

swift test \
  --package-path "$core_harness" \
  "${swift_cache_options[@]}" \
  --disable-sandbox \
  --scratch-path "$package_harness/CoreHarnessBuild" \
  "${strict_concurrency_options[@]}"

echo "Swift Package verification passed."
