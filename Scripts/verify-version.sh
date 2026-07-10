#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

version="$(tr -d '[:space:]' < VERSION)"
ruby Scripts/validate-semver.rb "$version" >/dev/null

pod_version="$(pod ipc spec NearWire.podspec | ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("version")')"
if [[ "$pod_version" != "$version" ]]; then
  echo "Podspec version $pod_version does not match VERSION $version." >&2
  exit 1
fi

echo "Version verification passed for $version."
