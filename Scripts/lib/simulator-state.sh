#!/bin/bash

nearwire_restore_simulator_state() {
  local initial_state="$1"
  local simulator_id="$2"
  local primary_status="$3"

  if [[ "$initial_state" == "Booted" || -z "$simulator_id" ]]; then
    return "$primary_status"
  fi

  if xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1; then
    return "$primary_status"
  fi

  echo "Failed to restore Simulator $simulator_id to its initial shutdown state." >&2
  if [[ "$primary_status" -eq 0 ]]; then
    return 98
  fi

  return "$primary_status"
}
