#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v pod >/dev/null 2>&1; then
  echo "CocoaPods 1.16 or later is required to validate NearWire.podspec." >&2
  exit 1
fi

pod_version="$(pod --version | tr -d '[:space:]')"
ruby Scripts/check-cocoapods-version.rb "$pod_version"

pod lib lint NearWire.podspec --private --skip-tests --no-ansi

echo "CocoaPods podspec verification passed."
