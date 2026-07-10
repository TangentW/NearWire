#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

paths=(
  "AGENTS.md"
  "CHANGELOG.md"
  "LICENSE"
  "NearWire.podspec"
  "Package.swift"
  "README.md"
  "Core"
  "SDK"
  "Viewer"
  "Demo"
  "IntegrationTests"
  "Documentation"
  "Scripts"
  "openspec"
)

set +e
matches="$(rg --pcre2 -n '\p{Han}|\p{Hiragana}|\p{Katakana}|\p{Hangul}' "${paths[@]}" \
  --glob '*.swift' \
  --glob '*.md' \
  --glob '*.sh' \
  --glob '*.rb' \
  --glob '*.podspec' \
  --glob '*.plist' \
  --glob '*.strings' \
  --glob '*.xcstrings' \
  --glob '*.pbxproj' \
  --glob '*.entitlements' \
  --glob '*.yml' \
  --glob '*.yaml' \
  --glob '*.json' \
  --glob '*.xml' 2>&1)"
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  echo "$matches" >&2
  echo "New repository natural-language content must be English." >&2
  exit 1
fi

if [[ "$status" -ne 1 ]]; then
  echo "$matches" >&2
  echo "The language scan failed to run." >&2
  exit 1
fi

echo "CJK character scan passed. Human review remains required for semantic language compliance."
