#!/bin/bash
# Installs statusline.sh as Claude Code's status line (~/.claude/statusline.sh), once the
# tests pass. Other Claude Code sessions sometimes edit the live copy, so this stops if the
# live file has changed since the last install from here; --force overwrites it anyway.
set -e
here=$(cd "$(dirname "$0")" && pwd)
live=$HOME/.claude/statusline.sh
stamp=$here/.installed   # checksum of the copy last installed from here

"$here/tests/run.sh" > /dev/null 2>&1 || { echo "tests failed: run tests/run.sh to see which"; exit 1; }
if [ -e "$live" ] && [ -e "$stamp" ] && [ "$1" != "--force" ] \
   && [ "$(shasum "$live" | cut -d' ' -f1)" != "$(cat "$stamp")" ]; then
  echo "$live has changed since the last install from here. Look at it first (--force overwrites it)."
  exit 1
fi
[ -e "$live" ] && cp "$live" "$live.bak"
cat "$here/statusline.sh" > "$live"   # in place, so the file keeps its permissions
chmod +x "$live"
shasum "$live" | cut -d' ' -f1 > "$stamp"
echo "installed $(cut -c1-7 "$stamp"); Claude Code picks it up at its next refresh"
