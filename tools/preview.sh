#!/bin/bash
# Renders the status line for a payload to a PNG (and prints it), from a throwaway HOME so
# no background check starts, with the reset and cache times moved to now.
# usage: tools/preview.sh [payload.json] [out.png]
set -e
here=$(cd "$(dirname "$0")/.." && pwd)
payload=${1:-$here/tools/sample-payload.json}
out=${2:-$here/preview.png}
h=$(mktemp -d "${TMPDIR:-/tmp}/bangarang-preview.XXXX")
trap 'rm -rf "$h"' EXIT
if [ "$(uname)" = Darwin ]; then c=$h/Library/Caches/claude-statusline; else c=$h/.cache/claude-statusline; fi
mkdir -p "$c"
now=$(date +%s)
echo "Max 20x" > "$c/plan"
jq -nc --argjson at "$now" '{at: $at, tone: "ok", text: ""}' > "$c/status.json"
jq -nc --argjson at "$now" '{at: $at, scoped: [{name: "Fable", percent: 5}]}' > "$c/usage.json"
touch "$c/status-checked" "$c/usage-checked"
jq -c --argjson now "$now" '.rate_limits.five_hour.resets_at = ($now + 7200)
    | .rate_limits.seven_day.resets_at = ($now + 518400)
    | .prompt_cache.expires_at = ($now + 2700)' "$payload" \
  | HOME=$h bash "$here/statusline.sh" > "$h/out.ansi"
cat "$h/out.ansi"; echo
python3 "$here/tools/ansi2png.py" "$out" < "$h/out.ansi"
echo "wrote $out"
