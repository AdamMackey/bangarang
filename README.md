# Bangarang

A Claude Code status line: two rows of everything worth watching, in a rainbow box.

```
╭────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮
│ »» B A N G A R A N G «« · ✓ Claude operational · Context █████░░░░░ 47% · Refill ████░░░░░░ 2hr · Cache ████████░░ 45m │
│ Opus 5.5 (1M) · Max Effort · Max 20x · $112.33 · Session █████░░░░░ 25% · Weekly ██████████ 14% · Fable ████░░░░░░  5% │
╰────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯
```

- **Row 1**: BANGARANG (always there; it grows or shrinks to fill the room row 2 leaves, so the rows
  line up), the status.claude.com verdict (`✓ Claude operational`, or `✕ Claude Outage` /
  `✕ Claude Maintenance` coloured by severity), then the context window, the time until the 5-hour
  limit refills, and the prompt cache's time left.
- **Row 2**: model, effort, fast mode, plan and session cost, then the 5-hour and weekly limits and
  per-model limits (Fable). Limit numbers turn amber from 70% and red from 90%; the lighter cells
  are where the current pace lands by the reset.
- The box is a soft OKLCH rainbow, red to violet.

## Use

```sh
./install.sh          # runs the tests, then copies statusline.sh to ~/.claude/statusline.sh
tests/run.sh          # the test suite (throwaway HOME; the real cache is never touched)
tools/preview.sh      # renders tools/sample-payload.json to preview.png and prints it
```

`~/.claude/settings.json` points at the installed copy:
`"statusLine": {"type": "command", "command": "~/.claude/statusline.sh", "refreshInterval": 60}`.
`install.sh` refuses to overwrite a live copy something else has changed since the last install
(`--force` to do it anyway); the previous live copy is kept as `statusline.sh.bak`.

## Where the numbers come from

- The JSON Claude Code pipes in: model, effort, fast mode, context window, cost, `rate_limits`
  (5-hour and weekly, with reset times), `prompt_cache` (warm, TTL, expiry). Needs Claude Code
  2.1.278 or later for the limits and cache.
- The plan (`Max 20x`) from `oauthAccount.organizationRateLimitTier` in `~/.claude.json`, and nothing
  else from that file; cached, re-read only when the file changes.
- Claude's status from status.claude.com, checked in the background every 20 minutes and reduced the
  way the Pulseous extension does it.
- Per-model weekly limits (Fable) from a headless `claude -p "/usage"` every 10 minutes, in the
  background. It makes no model call and costs nothing.
- Caches live in `~/Library/Caches/claude-statusline`. macOS only as it stands (BSD `stat` and `date`).

## Things learned the hard way

- Claude Code draws uncoloured status text as faint grey, so every piece has an explicit 24-bit
  colour. It repeats every colour code of the lines above at the start of each line, so long rows
  of codes (the box rules) end with a single reset.
- Claude Code only rewrites cells that changed, and Terminal.app can leave a row blank on screen
  after the window has been hidden while its text buffer still holds it. A box that never changes
  would stay blank, so its colours step one unit of blue on odd minutes (invisible) and every refresh
  repaints it.
- The line under the status line (`⏵⏵ auto mode on …`) belongs to Claude Code and cannot be written
  to. The prompt bar colour and session name above it come from `/color` (per session).
- SF Mono has the box-drawing glyphs, and its vertical line runs past the line height, so the sides
  join up. It has no hearts: Terminal draws `♥` from Menlo, one cell wide.

## Tools

- `tools/ansi2png.py`: draws ANSI output to a PNG (SF Mono, hearts from Menlo) to look at colours.
- `tools/tui-harness.py`: runs a throwaway `claude --bare` in a pseudo-terminal and prints the screen
  it draws, through pyte (`python3 -m venv tools/venv && tools/venv/bin/pip install pyte`). It sets
  `CLAUDE_CODE_NO_FLICKER=1`, which forces the full-screen renderer and skips its boot canary: killing
  a full-screen launch within 10 seconds of its first frame otherwise counts a strike in
  `~/.claude.json`, and two strikes turn full-screen off for that version. `CLAUDE_CODE_SANDBOXED=1`
  skips the trust prompt without saving trust.
- `tools/*.swift`: font coverage and window checks (`swift tools/fontcheck.swift`).
