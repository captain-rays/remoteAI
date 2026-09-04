#!/bin/sh
set -eu

output=${1:-agent/vendor/codex-schema/generated}
mkdir -p "$output"
codex app-server generate-json-schema --experimental --out "$output"
codex --version > "$output/CODEX_VERSION"
