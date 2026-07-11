#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/SDK/Sources/NearWire/Session/ProcessConnectionLease.swift"
FIXTURE="$ROOT/IntegrationTests/ProcessLeaseMultiImage"
BUILD_DIR="$(mktemp -d /tmp/nearwire-process-lease.XXXXXX)"
loader_pid=""
watchdog_pid=""

cleanup() {
  if [[ -n "$watchdog_pid" ]]; then
    kill "$watchdog_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$loader_pid" ]]; then
    kill "$loader_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

if rg -n '@_cdecl|\bdlopen\b|\bdlsym\b|nearwire_lease_[ab]_' "$ROOT/SDK/Sources"; then
  echo "Validation wrapper or loader code entered SDK production sources." >&2
  exit 1
fi

ruby "$ROOT/Scripts/check-process-lease-structure.rb" "$SOURCE"

sdk="$(xcrun --sdk macosx --show-sdk-path)"
architecture="$(uname -m)"
target="${architecture}-apple-macosx13.0"
common_options=(
  -swift-version 5
  -strict-concurrency=complete
  -warnings-as-errors
  -target "$target"
  -sdk "$sdk"
  -module-cache-path "$ROOT/.build/ModuleCache"
)

xcrun swiftc \
  "${common_options[@]}" \
  -parse-as-library \
  -emit-library \
  -module-name NearWireLeaseImageA \
  "$SOURCE" \
  "$FIXTURE/ImageAWrapper.swift" \
  -o "$BUILD_DIR/libNearWireLeaseImageA.dylib"

xcrun swiftc \
  "${common_options[@]}" \
  -parse-as-library \
  -emit-library \
  -module-name NearWireLeaseImageB \
  "$SOURCE" \
  "$FIXTURE/ImageBWrapper.swift" \
  -o "$BUILD_DIR/libNearWireLeaseImageB.dylib"

xcrun swiftc \
  "${common_options[@]}" \
  "$FIXTURE/Loader.swift" \
  -o "$BUILD_DIR/process-lease-loader"

nm -gU "$BUILD_DIR/libNearWireLeaseImageA.dylib" > "$BUILD_DIR/image-a.symbols"
nm -gU "$BUILD_DIR/libNearWireLeaseImageB.dylib" > "$BUILD_DIR/image-b.symbols"
rg -q '_nearwire_lease_a_claim$' "$BUILD_DIR/image-a.symbols"
rg -q '_nearwire_lease_b_claim$' "$BUILD_DIR/image-b.symbols"

"$BUILD_DIR/process-lease-loader" \
  "$BUILD_DIR/libNearWireLeaseImageA.dylib" \
  "$BUILD_DIR/libNearWireLeaseImageB.dylib" &
loader_pid=$!

(
  sleep 10
  if kill -0 "$loader_pid" >/dev/null 2>&1; then
    kill -TERM "$loader_pid" >/dev/null 2>&1 || true
    sleep 1
    kill -KILL "$loader_pid" >/dev/null 2>&1 || true
  fi
) &
watchdog_pid=$!

set +e
wait "$loader_pid"
loader_status=$?
set -e
loader_pid=""
kill "$watchdog_pid" >/dev/null 2>&1 || true
wait "$watchdog_pid" >/dev/null 2>&1 || true
watchdog_pid=""

if [[ "$loader_status" -ne 0 ]]; then
  echo "Process lease multi-image loader failed or exceeded its deadline." >&2
  exit "$loader_status"
fi

echo "Process lease validation artifacts remained temporary and outside package products."
