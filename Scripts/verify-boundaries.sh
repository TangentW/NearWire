#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/ModuleCache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT/.build/ModuleCache}"
export HOME="${NEARWIRE_BUILD_HOME:-$ROOT/.build/home}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$ROOT/.build/cache}"
mkdir -p \
  "$CLANG_MODULE_CACHE_PATH" \
  "$HOME" \
  "$XDG_CACHE_HOME" \
  "$ROOT/.build/config" \
  "$ROOT/.build/security"

ruby Scripts/check-swift-boundaries.rb

if rg -n \
  'SecureConnectionDriving|SecureByteChannel[[:space:]]*\(|NWConnection[[:space:]]*\(' \
  SDK/Sources; then
  echo "SDK sources bypass the mandatory secure transport factories." >&2
  exit 1
fi

echo "SDK secure transport construction boundary passed."

package_json="$(swift package \
  --cache-path "$ROOT/.build/cache" \
  --config-path "$ROOT/.build/config" \
  --security-path "$ROOT/.build/security" \
  --manifest-cache local \
  --disable-dependency-cache \
  --disable-build-manifest-caching \
  --disable-sandbox \
  dump-package)"

ruby Scripts/check-package-boundaries.rb --root "$ROOT" <<< "$package_json"

pod_json="$(pod ipc spec NearWire.podspec)"
ruby Scripts/check-podspec-boundaries.rb --root "$ROOT" <<< "$pod_json"

contract_dir="$(mktemp -d /tmp/nearwire-contract.XXXXXX)"
trap 'rm -rf "$contract_dir"' EXIT
package_json_path="$contract_dir/package.json"
pod_json_path="$contract_dir/podspec.json"
printf '%s' "$package_json" > "$package_json_path"
printf '%s' "$pod_json" > "$pod_json_path"
ruby Scripts/check-distribution-contract.rb \
  --package-json "$package_json_path" \
  --pod-json "$pod_json_path"

echo "Module boundary and dependency isolation verification passed."
