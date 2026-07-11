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
  Scripts/Fixtures/ForbiddenWirePayload.swift \
  Scripts/Fixtures/ForbiddenSDKImplementationType.swift \
  Scripts/Fixtures/ForbiddenPreHandshakeAPI.swift \
  Scripts/Fixtures/ForbiddenProcessLeaseAPI.swift

xcode_version="$(xcodebuild -version)"
xcode_major="$(awk '/Xcode/ { split($2, parts, "."); print parts[1]; exit }' <<< "$xcode_version")"
if [[ -z "$xcode_major" || "$xcode_major" -lt 16 ]]; then
  echo "Xcode 16 or later is required." >&2
  exit 1
fi

"$ROOT/Scripts/verify-process-lease.sh"
ruby "$ROOT/Scripts/check-session-admission-structure.rb" "$ROOT"

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

ios_module_path="$ROOT/.build/ios16/arm64-apple-ios/debug/Modules"
if [[ ! -d "$ios_module_path" ]]; then
  echo "iOS SDK module output is unavailable for consumer API checks." >&2
  exit 1
fi

for fixture in SDK/Tests/PublicAPIConsumer/*.swift; do
  xcrun swiftc \
    -typecheck \
    -swift-version 5 \
    -strict-concurrency=complete \
    -warnings-as-errors \
    -target arm64-apple-ios16.0 \
    -sdk "$ios_sdk" \
    -I "$ios_module_path" \
    "$fixture"
done

forbidden_sdk_spm="$package_harness/forbidden-sdk-spm.log"
if xcrun swiftc \
  -typecheck \
  -swift-version 5 \
  -target arm64-apple-ios16.0 \
  -sdk "$ios_sdk" \
  -I "$ios_module_path" \
  Scripts/Fixtures/ForbiddenSDKImplementationType.swift \
  >"$forbidden_sdk_spm" 2>&1; then
  echo "Swift Package consumer unexpectedly accessed an implementation-only SDK type." >&2
  exit 1
fi
if ! grep -Fq "cannot find type 'SDKSessionAdmission' in scope" "$forbidden_sdk_spm"; then
  echo "Swift Package implementation-type boundary failed for an unexpected reason." >&2
  cat "$forbidden_sdk_spm" >&2
  exit 1
fi

forbidden_lease_spm="$package_harness/forbidden-lease-spm.log"
if xcrun swiftc \
  -typecheck \
  -swift-version 5 \
  -target arm64-apple-ios16.0 \
  -sdk "$ios_sdk" \
  -I "$ios_module_path" \
  Scripts/Fixtures/ForbiddenProcessLeaseAPI.swift \
  >"$forbidden_lease_spm" 2>&1; then
  echo "Swift Package consumer unexpectedly accessed the process lease." >&2
  exit 1
fi
if ! grep -Fq "cannot find 'ProcessConnectionLeaseRegistry' in scope" \
  "$forbidden_lease_spm"; then
  echo "Swift Package process-lease boundary failed for an unexpected reason." >&2
  cat "$forbidden_lease_spm" >&2
  exit 1
fi

forbidden_pre_handshake_spm="$package_harness/forbidden-pre-handshake-spm.log"
if xcrun swiftc \
  -typecheck \
  -swift-version 5 \
  -target arm64-apple-ios16.0 \
  -sdk "$ios_sdk" \
  -I "$ios_module_path" \
  Scripts/Fixtures/ForbiddenPreHandshakeAPI.swift \
  >"$forbidden_pre_handshake_spm" 2>&1; then
  echo "Swift Package consumer unexpectedly accessed pre-handshake transport SPI." >&2
  exit 1
fi
if ! grep -Fq "cannot find 'WirePreHandshakeCodec' in scope" \
  "$forbidden_pre_handshake_spm"; then
  echo "Swift Package pre-handshake boundary failed for an unexpected reason." >&2
  cat "$forbidden_pre_handshake_spm" >&2
  exit 1
fi

spm_sdk_symbols="$package_harness/spm-sdk-symbols.log"
find "$ROOT/.build/ios16" -path '*/NearWire.build/*.o' -exec nm {} + \
  >"$spm_sdk_symbols"
if rg -n 'nearwire_lease_[ab]_' "$spm_sdk_symbols"; then
  echo "Swift Package SDK objects unexpectedly export validation wrapper symbols." >&2
  exit 1
fi

echo "iOS Swift Package SDK consumer API passed."

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

swift build \
  "${swift_cache_options[@]}" \
  --disable-sandbox \
  --scratch-path "$ROOT/.build/macos13" \
  --triple arm64-apple-macosx13.0 \
  --sdk "$macos_sdk" \
  --target NearWire \
  "${strict_concurrency_options[@]}"

macos_module_path="$ROOT/.build/macos13/arm64-apple-macosx/debug/Modules"
if [[ ! -d "$macos_module_path" ]]; then
  echo "macOS Core module output is unavailable for public API boundary checks." >&2
  exit 1
fi

xcrun swiftc \
  -typecheck \
  -swift-version 5 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target arm64-apple-macosx13.0 \
  -sdk "$macos_sdk" \
  -I "$macos_module_path" \
  SDK/Tests/PublicAPIConsumer/NearWirePublicAPIConsumer.swift

echo "Swift Package SDK consumer API passed."

sdk_api_json="$package_harness/nearwire-sdk-api.json"
xcrun swift-api-digester \
  -dump-sdk \
  -module NearWire \
  -I "$ios_module_path" \
  -target arm64-apple-ios16.0 \
  -sdk "$ios_sdk" \
  -o "$sdk_api_json"

ruby -rjson -e '
  document = JSON.parse(File.read(ARGV.fetch(0)))
  root = document.fetch("ABIRoot")
  root["children"] = root.fetch("children", []).reject { |child| child["kind"] == "Import" }
  public_api = JSON.generate(root)
  forbidden = %w[
    NearWireCore NearWireFlowControl NearWireTransport JSONValue EventDraft
    EventEnvelope BoundedEventQueue SecureByteChannel NWConnection NWListener
    NWParameters SecIdentity ProcessConnectionLease WirePreHandshakeCodec
    WirePreHandshakeMessage WireAdmittedMessage WireMessagePayload
  ]
  violations = forbidden.select { |name| public_api.include?(name) }
  abort "Supported SDK API exposes implementation-only types: #{violations.join(", ")}" unless violations.empty?
' "$sdk_api_json"

echo "SDK implementation-type API boundary passed."

cocoapods_module_dir="$package_harness/CocoaPodsModule"
mkdir -p "$cocoapods_module_dir"
cocoapods_sources=()
while IFS= read -r source; do
  cocoapods_sources+=("$source")
done < <(find Core/Sources SDK/Sources/NearWire -type f -name '*.swift' -print | sort)

SDKROOT="$ios_sdk" xcrun --sdk iphoneos swiftc \
  -parse-as-library \
  -emit-library \
  -module-name NearWire \
  -emit-module-path "$cocoapods_module_dir/NearWire.swiftmodule" \
  -o "$cocoapods_module_dir/libNearWire.dylib" \
  -swift-version 5 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target arm64-apple-ios16.0 \
  -sdk "$ios_sdk" \
  "${cocoapods_sources[@]}"

cocoapods_sdk_symbols="$package_harness/cocoapods-sdk-symbols.log"
nm -gU "$cocoapods_module_dir/libNearWire.dylib" > "$cocoapods_sdk_symbols"
if rg -n 'nearwire_lease_[ab]_' "$cocoapods_sdk_symbols"; then
  echo "CocoaPods SDK binary unexpectedly exports validation wrapper symbols." >&2
  exit 1
fi

for fixture in SDK/Tests/PublicAPIConsumer/*.swift; do
  xcrun swiftc \
    -typecheck \
    -swift-version 5 \
    -strict-concurrency=complete \
    -warnings-as-errors \
    -target arm64-apple-ios16.0 \
    -sdk "$ios_sdk" \
    -I "$cocoapods_module_dir" \
    "$fixture"
done

forbidden_sdk_pod="$package_harness/forbidden-sdk-pod.log"
if xcrun swiftc \
  -typecheck \
  -swift-version 5 \
  -target arm64-apple-ios16.0 \
  -sdk "$ios_sdk" \
  -I "$cocoapods_module_dir" \
  Scripts/Fixtures/ForbiddenSDKImplementationType.swift \
  >"$forbidden_sdk_pod" 2>&1; then
  echo "CocoaPods consumer unexpectedly accessed an implementation-only SDK type." >&2
  exit 1
fi
if ! grep -Fq "cannot find type 'SDKSessionAdmission' in scope" "$forbidden_sdk_pod"; then
  echo "CocoaPods implementation-type boundary failed for an unexpected reason." >&2
  cat "$forbidden_sdk_pod" >&2
  exit 1
fi

forbidden_lease_pod="$package_harness/forbidden-lease-pod.log"
if xcrun swiftc \
  -typecheck \
  -swift-version 5 \
  -target arm64-apple-ios16.0 \
  -sdk "$ios_sdk" \
  -I "$cocoapods_module_dir" \
  Scripts/Fixtures/ForbiddenProcessLeaseAPI.swift \
  >"$forbidden_lease_pod" 2>&1; then
  echo "CocoaPods consumer unexpectedly accessed the process lease." >&2
  exit 1
fi
if ! grep -Fq "cannot find 'ProcessConnectionLeaseRegistry' in scope" \
  "$forbidden_lease_pod"; then
  echo "CocoaPods process-lease boundary failed for an unexpected reason." >&2
  cat "$forbidden_lease_pod" >&2
  exit 1
fi

forbidden_pre_handshake_pod="$package_harness/forbidden-pre-handshake-pod.log"
if xcrun swiftc \
  -typecheck \
  -swift-version 5 \
  -target arm64-apple-ios16.0 \
  -sdk "$ios_sdk" \
  -I "$cocoapods_module_dir" \
  Scripts/Fixtures/ForbiddenPreHandshakeAPI.swift \
  >"$forbidden_pre_handshake_pod" 2>&1; then
  echo "CocoaPods consumer unexpectedly accessed pre-handshake transport SPI." >&2
  exit 1
fi
if ! grep -Fq "cannot find 'WirePreHandshakeCodec' in scope" \
  "$forbidden_pre_handshake_pod"; then
  echo "CocoaPods pre-handshake boundary failed for an unexpected reason." >&2
  cat "$forbidden_pre_handshake_pod" >&2
  exit 1
fi

cocoapods_api_json="$package_harness/nearwire-cocoapods-api.json"
xcrun swift-api-digester \
  -dump-sdk \
  -module NearWire \
  -I "$cocoapods_module_dir" \
  -target arm64-apple-ios16.0 \
  -sdk "$ios_sdk" \
  -o "$cocoapods_api_json"

ruby -rjson -e '
  def public_usrs(path)
    root = JSON.parse(File.read(path)).fetch("ABIRoot")
    root.fetch("children", []).reject { |child| child["kind"] == "Import" }
      .flat_map { |node| collect(node) }.compact.sort.uniq
  end

  def collect(node)
    return [] unless Array(node["spi_group_names"]).empty?
    [node["usr"]] + node.fetch("children", []).flat_map { |child| collect(child) }
  end

  package_usrs = public_usrs(ARGV.fetch(0))
  pod_usrs = public_usrs(ARGV.fetch(1))
  missing = package_usrs - pod_usrs
  extra = pod_usrs - package_usrs
  unless missing.empty? && extra.empty?
    abort "SwiftPM/CocoaPods public API mismatch. Missing: #{missing.inspect}; extra: #{extra.inspect}"
  end
' "$sdk_api_json" "$cocoapods_api_json"

echo "iOS CocoaPods same-module SDK consumer and API parity passed."

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

real_tls_output="$(swift test \
  --package-path "$package_harness" \
  "${swift_cache_options[@]}" \
  --disable-sandbox \
  --scratch-path "$package_harness/RealTLSAdmissionBuild" \
  --filter SDKSessionAdmissionTests.testRealTLSProductionChannelCompletesAdmissionSequence \
  "${strict_concurrency_options[@]}" 2>&1)"
printf '%s\n' "$real_tls_output"
if grep -Fq "Test skipped" <<< "$real_tls_output"; then
  echo "Real TLS active-session integration requires an unrestricted macOS validation environment." >&2
  exit 1
fi
if ! grep -Fq "Executed 1 test, with 0 failures" <<< "$real_tls_output"; then
  echo "Real TLS active-session result was not proven by exactly one passing test." >&2
  exit 1
fi

echo "Real TLS active-session integration passed."

echo "Swift Package verification passed."
