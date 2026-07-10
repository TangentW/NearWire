#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v openspec >/dev/null 2>&1; then
  echo "OpenSpec is required." >&2
  exit 1
fi

DO_NOT_TRACK=1 openspec validate --all --strict --no-interactive
"$ROOT/Scripts/verify-structure.sh"
"$ROOT/Scripts/verify-english.sh"
"$ROOT/Scripts/Tests/validation-tools.sh"
"$ROOT/Scripts/verify-version.sh"
"$ROOT/Scripts/verify-boundaries.sh"
"$ROOT/Scripts/verify-package.sh"
"$ROOT/Scripts/verify-podspec.sh"

echo "All bootstrap quality gates passed."
