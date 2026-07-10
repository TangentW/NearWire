#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fixture_root="$(mktemp -d /tmp/nearwire-evidence-capture.XXXXXX)"
trap 'rm -rf "$fixture_root"' EXIT

printf '%s\n' 'RUN_ID: stale-run' 'EXIT_STATUS: 0' > "$fixture_root/09-cocoapods.log"

set +e
NEARWIRE_TEST_FAIL_EVIDENCE_SEQUENCE=01 \
  ./Scripts/capture-bootstrap-evidence.sh "$fixture_root" all \
  >/dev/null 2>&1
capture_status=$?
set -e

if [[ "$capture_status" -eq 0 ]]; then
  echo "Expected the forced evidence capture failure to propagate." >&2
  exit 1
fi

if [[ -e "$fixture_root/09-cocoapods.log" ]]; then
  echo "A stale later evidence log survived a failed canonical capture." >&2
  exit 1
fi

grep -Fxq "STATUS: failed" "$fixture_root/all-capture-status.log"

if ./Scripts/capture-bootstrap-evidence.sh "$fixture_root" verify >/dev/null 2>&1; then
  echo "Expected incomplete canonical evidence verification to fail." >&2
  exit 1
fi

tee_fixture="$fixture_root/tee-failure"
mkdir -p "$tee_fixture"
set +e
NEARWIRE_TEST_FAIL_TEE_SEQUENCE=01 \
  ./Scripts/capture-bootstrap-evidence.sh "$tee_fixture" all \
  >/dev/null 2>&1
tee_status=$?
set -e

if [[ "$tee_status" -eq 0 ]]; then
  echo "Expected an evidence log write failure to propagate." >&2
  exit 1
fi
grep -Fxq "STATUS: failed" "$tee_fixture/all-capture-status.log"

integrity_fixture="$fixture_root/integrity-failure"
mkdir -p "$integrity_fixture"
integrity_run_id="integrity-test-run"
printf '%s\n' \
  'MODE: all' \
  "RUN_ID: $integrity_run_id" \
  'STATUS: in_progress' \
  'EXIT_STATUS: -' \
  > "$integrity_fixture/all-capture-status.log"

gate_names=(
  environment
  openspec
  structure
  language
  validation-tools
  version
  boundaries
  swift-package
)

for index in 0 1 2 3 4 5 6 7; do
  sequence="$(printf '%02d' $((index + 1)))"
  printf '%s\n' \
    "RUN_ID: $integrity_run_id" \
    "GATE_ID: ${gate_names[$index]}" \
    'EXIT_STATUS: 0' \
    > "$integrity_fixture/$sequence-${gate_names[$index]}.log"
done

if ./Scripts/capture-bootstrap-evidence.sh "$integrity_fixture" verify-in-progress >/dev/null 2>&1; then
  echo "Expected corrupted canonical evidence verification to fail." >&2
  exit 1
fi
grep -Fxq "STATUS: in_progress" "$integrity_fixture/all-capture-status.log"

printf '%s\n' \
  "RUN_ID: $integrity_run_id" \
  'GATE_ID: wrong-gate' \
  'EXIT_STATUS: 0' \
  > "$integrity_fixture/09-cocoapods.log"
if ./Scripts/capture-bootstrap-evidence.sh "$integrity_fixture" verify-in-progress >/dev/null 2>&1; then
  echo "Expected a wrong evidence gate identity to fail verification." >&2
  exit 1
fi

printf '%s\n' \
  "RUN_ID: $integrity_run_id" \
  'GATE_ID: cocoapods' \
  'EXIT_STATUS: 0' \
  > "$integrity_fixture/09-cocoapods.log"
./Scripts/capture-bootstrap-evidence.sh "$integrity_fixture" verify-in-progress >/dev/null

bypass_fixture="$fixture_root/bypass-attempt"
mkdir -p "$bypass_fixture"
set +e
NEARWIRE_TEST_EVIDENCE_COMMANDS=pass \
NEARWIRE_TEST_FAIL_EVIDENCE_SEQUENCE=02 \
  ./Scripts/capture-bootstrap-evidence.sh "$bypass_fixture" all \
  >/dev/null 2>&1
bypass_status=$?
set -e

if [[ "$bypass_status" -eq 0 ]]; then
  echo "Expected the bypass-attempt capture to fail at sequence 02." >&2
  exit 1
fi

if rg -q 'Test-mode command passed' "$bypass_fixture/01-environment.log"; then
  echo "A test environment variable bypassed a real evidence command." >&2
  exit 1
fi
grep -q '^Xcode ' "$bypass_fixture/01-environment.log"
grep -Fxq "STATUS: failed" "$bypass_fixture/all-capture-status.log"

echo "Evidence capture failure tests passed."
