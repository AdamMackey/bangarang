#!/bin/bash
# Installs statusline.sh as Claude Code's status line (~/.claude/statusline.sh), once the
# tests pass. Other Claude Code sessions sometimes edit the live copy, so this stops if the
# live file has changed since the last install from here; --force overwrites it anyway.
set -e
here=$(cd "$(dirname "$0")" && pwd)
live=$HOME/.claude/statusline.sh
# checksum of the copy last installed from here, one stamp per target, so installing into
# another HOME (a test run, say) never trips the guard for the real one
stamp=$here/.installed-$(printf %s "$live" | cksum | cut -d' ' -f1)
sum() { if command -v shasum >/dev/null; then shasum "$1"; else sha1sum "$1"; fi | cut -d' ' -f1; }

command -v jq >/dev/null || { echo "Bangarang needs jq (brew install jq, or apt install jq)"; exit 1; }
if command -v python3 >/dev/null; then
  "$here/tests/run.sh" > /dev/null 2>&1 || { echo "tests failed: run tests/run.sh to see which"; exit 1; }
else
  echo "python3 not found, so the tests were skipped"
fi
if [ -e "$live" ] && [ -e "$stamp" ] && [ "$1" != "--force" ] \
   && [ "$(sum "$live")" != "$(cat "$stamp")" ]; then
  echo "$live has changed since the last install from here. Look at it first (--force overwrites it)."
  exit 1
fi
mkdir -p "$HOME/.claude"
if [ -e "$live" ]; then
  cp "$live" "$live.bak"
  echo "kept the previous status line as $live.bak"
fi
cat "$here/statusline.sh" > "$live"   # in place, so the file keeps its permissions
chmod +x "$live"
sum "$live" > "$stamp"
echo "installed $(cut -c1-7 "$stamp"); Claude Code picks it up at its next refresh"

if ! grep -q 'statusline.sh' "$HOME/.claude/settings.json" 2>/dev/null; then
  cat <<'EOF'

One more step: add this to ~/.claude/settings.json (add "--usage" after statusline.sh
for the per-model weekly limits, which runs a headless `claude -p "/usage"` every 10 minutes):

  "statusLine": {"type": "command", "command": "~/.claude/statusline.sh", "refreshInterval": 60}
EOF
fi
