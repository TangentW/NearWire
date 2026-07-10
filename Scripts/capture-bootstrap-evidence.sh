#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_DIR="${1:-$ROOT/openspec/changes/project-bootstrap/evidence/raw}"
MODE="${2:-all}"
RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
CAPTURE_COMPLETE=false
STATUS_FILE=""

mkdir -p "$EVIDENCE_DIR"
cd "$ROOT"

run_and_capture() {
  local sequence="$1"
  local name="$2"
  shift 2

  local log="$EVIDENCE_DIR/${sequence}-${name}.log"
  local status
  local pipeline_status

  set +e
  {
    echo "COMMAND:"
    printf ' %q' "$@"
    echo
    echo "RUN_ID: $RUN_ID"
    echo "GATE_ID: $name"
    echo "STARTED_AT_UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
    if [[ "${NEARWIRE_TEST_FAIL_EVIDENCE_SEQUENCE:-}" == "$sequence" ]]; then
      echo "Forced evidence-capture failure for test sequence $sequence." >&2
      status=97
    else
      "$@"
      status=$?
    fi
    echo
    echo "EXIT_STATUS: $status"
    echo "FINISHED_AT_UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    exit "$status"
  } 2>&1 | write_evidence_log "$sequence" "$log"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e

  if [[ "${pipeline_status[1]}" -ne 0 ]]; then
    echo "Evidence log write failed for sequence $sequence." >&2
    return 99
  fi

  if [[ "${pipeline_status[0]}" -ne 0 ]]; then
    return "${pipeline_status[0]}"
  fi
}

write_evidence_log() {
  local sequence="$1"
  local log="$2"

  if [[ "${NEARWIRE_TEST_FAIL_TEE_SEQUENCE:-}" == "$sequence" ]]; then
    return 74
  fi

  tee "$log"
}

write_capture_status() {
  local state="$1"
  local exit_status="$2"
  local temporary_status

  temporary_status="$(mktemp "$EVIDENCE_DIR/.capture-status.XXXXXX")"
  {
    echo "MODE: $MODE"
    echo "RUN_ID: $RUN_ID"
    echo "STATUS: $state"
    echo "EXIT_STATUS: $exit_status"
    echo "UPDATED_AT_UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } > "$temporary_status"
  mv "$temporary_status" "$STATUS_FILE"
}

capture_exit() {
  local status=$?
  trap - EXIT

  if [[ "$CAPTURE_COMPLETE" != true && -n "$STATUS_FILE" ]]; then
    write_capture_status "failed" "$status"
  fi

  exit "$status"
}

begin_capture() {
  STATUS_FILE="$EVIDENCE_DIR/$MODE-capture-status.log"

  local sequence
  local stale_log
  for sequence in "$@"; do
    for stale_log in "$EVIDENCE_DIR/$sequence-"*.log; do
      if [[ -e "$stale_log" ]]; then
        rm -f "$stale_log"
      fi
    done
  done

  write_capture_status "in_progress" "-"
  trap capture_exit EXIT
}

complete_capture() {
  write_capture_status "complete" "0"
  CAPTURE_COMPLETE=true
}

verify_complete_evidence() {
  local expected_state="${1:-complete}"
  local status_file="$EVIDENCE_DIR/all-capture-status.log"
  if [[ ! -f "$status_file" ]] || ! grep -Fxq "STATUS: $expected_state" "$status_file"; then
    echo "Canonical all-mode evidence capture is not in the expected $expected_state state." >&2
    return 1
  fi

  local run_id
  run_id="$(awk -F': ' '/^RUN_ID:/ { print $2; exit }' "$status_file")"
  if [[ -z "$run_id" ]]; then
    echo "Canonical evidence status has no run ID." >&2
    return 1
  fi

  local sequence
  local gate_index=0
  local gate_names=(
    environment
    openspec
    structure
    language
    validation-tools
    version
    boundaries
    swift-package
    cocoapods
  )
  local log
  for sequence in 01 02 03 04 05 06 07 08 09; do
    log="$(find "$EVIDENCE_DIR" -maxdepth 1 -type f -name "$sequence-*.log" -print)"
    if [[ -z "$log" || "$(printf '%s\n' "$log" | wc -l | tr -d ' ')" != "1" ]]; then
      echo "Expected exactly one canonical log for sequence $sequence." >&2
      return 1
    fi
    grep -Fxq "RUN_ID: $run_id" "$log" || {
      echo "Evidence log $log belongs to a different run." >&2
      return 1
    }
    grep -Fxq "GATE_ID: ${gate_names[$gate_index]}" "$log" || {
      echo "Evidence log $log has an unexpected gate identity." >&2
      return 1
    }
    grep -Fxq "EXIT_STATUS: 0" "$log" || {
      echo "Evidence log $log did not pass." >&2
      return 1
    }
    gate_index=$((gate_index + 1))
  done

  echo "Canonical bootstrap evidence is complete and internally consistent."
}

if [[ "$MODE" == "verify" ]]; then
  verify_complete_evidence
  exit 0
fi

if [[ "$MODE" == "verify-in-progress" ]]; then
  verify_complete_evidence in_progress
  exit 0
fi

if [[ "$MODE" == "cocoapods" ]]; then
  begin_capture 09
  run_and_capture "09" "cocoapods" ./Scripts/verify-podspec.sh
  complete_capture
  echo "CocoaPods evidence captured in $EVIDENCE_DIR."
  exit 0
fi

if [[ "$MODE" == "swift-package" ]]; then
  begin_capture 08
  run_and_capture "08" "swift-package" ./Scripts/verify-package.sh
  complete_capture
  echo "Swift Package evidence captured in $EVIDENCE_DIR."
  exit 0
fi

if [[ "$MODE" == "preflight" ]]; then
  begin_capture 01 02 03 04 05 06 07
  run_and_capture "01" "environment" bash -c \
    'xcodebuild -version; swift --version; pod --version; openspec --version'
  run_and_capture "02" "openspec" env DO_NOT_TRACK=1 \
    openspec --no-color validate --all --strict --no-interactive
  run_and_capture "03" "structure" ./Scripts/verify-structure.sh
  run_and_capture "04" "language" ./Scripts/verify-english.sh
  run_and_capture "05" "validation-tools" ./Scripts/Tests/validation-tools.sh
  run_and_capture "06" "version" ./Scripts/verify-version.sh
  run_and_capture "07" "boundaries" ./Scripts/verify-boundaries.sh
  complete_capture
  echo "Preflight evidence captured in $EVIDENCE_DIR."
  exit 0
fi

if [[ "$MODE" != "all" ]]; then
  echo "Unknown evidence capture mode: $MODE" >&2
  exit 1
fi

begin_capture 01 02 03 04 05 06 07 08 09

run_and_capture "01" "environment" bash -c \
  'xcodebuild -version; swift --version; pod --version; openspec --version'
run_and_capture "02" "openspec" env DO_NOT_TRACK=1 \
  openspec --no-color validate --all --strict --no-interactive
run_and_capture "03" "structure" ./Scripts/verify-structure.sh
run_and_capture "04" "language" ./Scripts/verify-english.sh
run_and_capture "05" "validation-tools" ./Scripts/Tests/validation-tools.sh
run_and_capture "06" "version" ./Scripts/verify-version.sh
run_and_capture "07" "boundaries" ./Scripts/verify-boundaries.sh
run_and_capture "08" "swift-package" ./Scripts/verify-package.sh
run_and_capture "09" "cocoapods" ./Scripts/verify-podspec.sh

verify_complete_evidence in_progress
complete_capture

echo "Raw bootstrap evidence captured in $EVIDENCE_DIR."
