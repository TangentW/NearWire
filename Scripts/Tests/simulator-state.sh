#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/Scripts/lib/simulator-state.sh"

shutdown_calls=0
stub_shutdown_status=0

xcrun() {
  shutdown_calls=$((shutdown_calls + 1))
  return "$stub_shutdown_status"
}

nearwire_restore_simulator_state "Booted" "already-booted" 0
if [[ "$shutdown_calls" -ne 0 ]]; then
  echo "An initially booted Simulator must not be shut down." >&2
  exit 1
fi

nearwire_restore_simulator_state "Shutdown" "booted-by-verifier" 0
if [[ "$shutdown_calls" -ne 1 ]]; then
  echo "A Simulator booted by the verifier must be shut down." >&2
  exit 1
fi

stub_shutdown_status=1
set +e
nearwire_restore_simulator_state "Shutdown" "cleanup-failure" 0 >/dev/null 2>&1
cleanup_status=$?
set -e
if [[ "$cleanup_status" -ne 98 ]]; then
  echo "A cleanup failure must fail an otherwise successful verification." >&2
  exit 1
fi

set +e
nearwire_restore_simulator_state "Shutdown" "primary-failure" 42 >/dev/null 2>&1
preserved_status=$?
set -e
if [[ "$preserved_status" -ne 42 ]]; then
  echo "Cleanup must preserve an existing primary failure status." >&2
  exit 1
fi

echo "Simulator state restoration tests passed."
