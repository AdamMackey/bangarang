#!/bin/bash
# Bangarang, a Claude Code status line: two rows in a rainbow box.
#   1. BANGARANG (always there, sized to fill the room row 2 leaves) and Claude's
#      service from status.claude.com, the way Pulseous shows it (✓ Claude
#      operational, ✕ Claude Outage or Maintenance in the colour of how bad it
#      is, ? when there is no fresh answer); then bars for the context window,
#      the time until the 5-hour limit refills, and the prompt cache.
#   2. The live model (and its context size), effort, fast mode, your plan
#      (Max 20x and so on) and what the session has cost; then bars for the
#      5-hour and weekly limits, each with a pace forecast, and with --usage the
#      per-model weekly limits (Fable) from a headless /usage.
# Claude Code pipes session JSON to stdin after each turn, whenever the model,
# effort or fast mode changes, and every "refreshInterval" seconds. Wired up by
# "statusLine" in ~/.claude/settings.json. The rows are laid out as a table
# (see layout): their dots and bars line up, and they end on the same column.
# Field names verified against the 2.1.278 and 2.1.280 builds: model.display_name,
# model.id, effort.level (only sent for models that take an effort setting),
# fast_mode, context_window.used_percentage (0-100, null until the first reply)
# and .context_window_size, cost.total_cost_usd (the session's running total at
# API prices), and rate_limits.five_hour / .seven_day as {used_percentage in
# 0.1 steps, resets_at in epoch seconds}; a window drops out once it resets.

# Runs on macOS and Linux. The caches live in ~/Library/Caches on macOS and in
# $XDG_CACHE_HOME (~/.cache) elsewhere.
if [ "$(uname)" = Darwin ]; then
  cache="$HOME/Library/Caches/claude-statusline"
else
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
fi
# A file's modification time in epoch seconds: GNU stat takes -c, BSD stat -f.
if stat -c %Y / >/dev/null 2>&1; then mtime() { stat -c %Y "$1"; }; else mtime() { stat -f %m "$1"; }; fi
# Run a command in its own session (setsid on Linux, perl where there is none),
# and with a 60-second limit (timeout on Linux, perl on macOS).
detach() { if command -v setsid >/dev/null; then setsid "$@"; else perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' "$@"; fi; }
limit60() { if command -v timeout >/dev/null; then timeout 60 "$@"; else perl -e 'alarm 60; exec @ARGV' "$@"; fi; }

# The background half: fetch status.claude.com and boil it down to one small
# verdict, {at, tone, text}, drawn the way Pulseous draws it. A failed fetch
# leaves the last verdict alone and marks status-failed instead.
if [ "$1" = "--fetch-status" ]; then
  set -o pipefail
  mkdir -p "$cache"
  tmp="$cache/status.json.$$"
  if curl -fsS --max-time 10 -H 'Accept: application/json' \
       https://status.claude.com/api/v2/summary.json |
     jq -c --argjson at "$(date +%s)" '
       # Pulseous ranks: operational 0, maintenance 1, degraded or minor 2,
       # partial outage or major 3, major outage or critical 4. Unknown is 2.
       def rank: {operational: 0, under_maintenance: 1, degraded_performance: 2,
                  partial_outage: 3, major_outage: 4}[.] // 2;
       def page_rank: {none: 0, maintenance: 1, minor: 2, major: 3, critical: 4}[.] // 2;
       def wording: {under_maintenance: "under maintenance", degraded_performance: "degraded",
                   partial_outage: "partial outage", major_outage: "major outage"}[.]
                  // gsub("_"; " ");
       # Claude Code and the API it runs on come first, then the worst, then page order.
       def relevance: if test("^Claude Code\\b") then 0 elif test("^Claude API\\b") then 1 else 2 end;
       def clip: if length > 60 then .[:59] + "…" else . end;
       . as $page
       | ([.components[]? | objects | select(.group != true)
           | .name = (.name // "A Claude service") | .status = (.status // "operational")
           | select(.status != "operational")]
          | sort_by([(.name | relevance), -(.status | rank), (.position // 0)])) as $bad
       # Worst of the page roll-up and every component, so a red component
       # still counts if the roll-up lags behind.
       | ([$page.status.indicator // "none" | page_rank] + [$bad[].status | rank] | max) as $worst
       | {at: $at,
          tone: ["ok", "info", "warn", "bad", "crit"][$worst],
          text: (if $bad != [] then
                   # "Claude API (api.anthropic.com)" reads as "Claude API".
                   ([$bad[:3][] | "\(.name | sub(" \\(.*\\)$"; "")) \(.status | wording)"] | join(", "))
                   + (if ($bad | length) > 3 then " +\(($bad | length) - 3) more" else "" end)
                 elif $worst > 0 then
                   # An incident can be open before any component changes state.
                   (($page.incidents // [])[0].name
                    // ([($page.scheduled_maintenances // [])[] | select(.status == "in_progress")][0].name)
                    // $page.status.description // "Claude is having problems") | clip
                 else "" end)}
     ' > "$tmp" && [ -s "$tmp" ]; then
    mv -f "$tmp" "$cache/status.json" && rm -f "$cache/status-failed"
  else
    rm -f "$tmp"
    touch "$cache/status-failed"
  fi
  exit 0
fi

# The per-model weekly limits (Fable and so on) are not in the status line
# JSON, and only Claude Code can ask claude.ai for them with its own login. Its
# /usage command works headless: no model call, no cost, about five seconds.
# Run from the home folder so it opens no new project. The report is text, so
# the "Current week (Fable): 2% used" lines are picked out; a report without
# any "Current week" line (not logged in, say) counts as a failure.
if [ "$1" = "--fetch-usage" ]; then
  set -o pipefail
  mkdir -p "$cache"
  tmp="$cache/usage.json.$$"
  claude_bin=$(command -v claude || echo "$HOME/.local/bin/claude")
  if cd "$HOME" && limit60 "$claude_bin" -p "/usage" --output-format json --no-session-persistence </dev/null 2>/dev/null |
     jq -c --argjson at "$(date +%s)" '
       (.result // "") as $text
       | if ($text | test("Current week")) then
           {at: $at,
            scoped: [$text | scan("Current week \\(([^)]+)\\): ([0-9]+)% used")
                     | {name: .[0], percent: (.[1] | tonumber)} | select(.name != "all models")]}
         else error("no usage report") end' > "$tmp" && [ -s "$tmp" ]; then
    mv -f "$tmp" "$cache/usage.json" && rm -f "$cache/usage-failed"
  else
    rm -f "$tmp"
    touch "$cache/usage-failed"
  fi
  exit 0
fi

now=$(date +%s)

# The per-model weekly limits (Fable and so on) cost a headless claude run every
# ten minutes, so they are off unless asked for: --usage on the status line
# command, or BANGARANG_USAGE=1 in its environment.
# The word at the top left is BANGARANG unless --phrase WORD (or --phrase=WORD, or
# BANGARANG_PHRASE=WORD) makes it yours.
usage_on=0
word="${BANGARANG_PHRASE:-}"
prev=""
for a in "$@"; do
  case "$a" in
    --usage) usage_on=1 ;;
    --phrase=*) word="${a#--phrase=}" ;;
  esac
  [ "$prev" = "--phrase" ] && word="$a"
  prev="$a"
done
[ "${BANGARANG_USAGE:-}" = 1 ] && usage_on=1
[ -n "$word" ] || word=BANGARANG

# Look at status.claude.com at most every two minutes, in the background, so the
# line never waits on the network. setsid gives the check its own session, so it
# finishes even if Claude Code tidies up this script's process group.
# status-failed then only ever describes the latest check.
if [ ! -e "$cache/status-checked" ] || [ $((now - $(mtime "$cache/status-checked"))) -ge 120 ]; then
  mkdir -p "$cache" && touch "$cache/status-checked" && rm -f "$cache/status-failed"
  detach /bin/bash "$0" --fetch-status </dev/null >/dev/null 2>&1 &
fi

# The per-model limits move slowly: refresh them every ten minutes, the same way.
if [ "$usage_on" = 1 ] && { [ ! -e "$cache/usage-checked" ] || [ $((now - $(mtime "$cache/usage-checked"))) -ge 600 ]; }; then
  mkdir -p "$cache" && touch "$cache/usage-checked" && rm -f "$cache/usage-failed"
  detach /bin/bash "$0" --fetch-usage </dev/null >/dev/null 2>&1 &
fi

# The plan is not in the status line JSON, but Claude Code keeps the account's
# tier in ~/.claude.json (default_claude_max_20x and so on). Only that is read,
# and only after the file changes, so a half-written file keeps the last answer.
if [ "$HOME/.claude.json" -nt "$cache/plan" ]; then
  mkdir -p "$cache"
  if jq -r '.oauthAccount // {}
        | (.organizationRateLimitTier // .userRateLimitTier // "") as $tier
        | if ($tier | test("max_[0-9]+x$")) then "Max " + ($tier | capture("max_(?<n>[0-9]+x)$").n)
          else {claude_max: "Max", claude_pro: "Pro", claude_team: "Team",
                claude_enterprise: "Enterprise"}[.organizationType // ""] // "" end' \
       "$HOME/.claude.json" > "$cache/plan.$$" 2>/dev/null; then
    mv -f "$cache/plan.$$" "$cache/plan"
  else
    rm -f "$cache/plan.$$"
  fi
fi

exec jq -r --argjson now "$now" --arg word "$word" \
  --arg plan "$(cat "$cache/plan" 2>/dev/null)" \
  --arg usage "$([ "$usage_on" = 1 ] && cat "$cache/usage.json" 2>/dev/null)" \
  --arg usage_failed "$([ "$usage_on" = 1 ] && [ -e "$cache/usage-failed" ] && echo 1)" \
  --argjson checked "$(mtime "$cache/status-checked" 2>/dev/null || echo 0)" \
  --arg status "$(cat "$cache/status.json" 2>/dev/null)" \
  --arg failed "$([ -e "$cache/status-failed" ] && echo 1)" '
  # The model name, "(1M)" and the effort are GIGA PURPLE whatever the model:
  # the violet Claude Code gives "accept edits on" (its dark theme autoAccept,
  # rgb 175 135 255), bluer than the 256-colour 134 they had before (Adam:
  # "the model name and effort color should be bluer"). hue is the colour part
  # of the escape code.
  def hue: "38;2;175;135;255";
  def size: if . >= 1000000 then "\(. / 1000000 | floor)M" elif . >= 1000 then "\(. / 1000 | floor)k" else tostring end;
  def dollars: (. * 100 | round) as $c | "$\($c / 100 | floor).\($c % 100 | tostring | if length < 2 then "0" + . else . end)";
  # Every piece has a colour: Claude Code draws uncoloured text in a faint grey
  # (measured #565656 on screen), while colours show at full strength. All are
  # exact 24-bit values for this dark terminal, which Claude Code keeps as rgb.
  def tint(c; s): if s == "" then "" else c + s + "\u001b[0m" end;
  def rep(s; n): if n > 0 then s * n else "" end;
  def c_words:  "\u001b[38;2;208;195;167m";   # sand: the words around numbers (warm, so it never competes with the numbers)
  def c_dot:    "\u001b[38;2;98;106;133m";    # slate: the dots between pieces
  def c_fast:   "\u001b[38;2;240;195;90m";    # gold: fast mode
  def c_ok:     "\u001b[38;2;135;169;141m";   # calm sage: all clear, washed out and a little warm, easy on the eyes
  def c_plan:   "\u001b[38;2;232;142;144m";   # pale rose: the plan, pinker and paler than the Meterous warning red
  # What the session has cost is in the pale rose of the plan, so the plan and its
  # spend read as one pair (Adam, 2026-09-25: "the dollar value should be same
  # colour as Max x20"). It was GIGA ORANGE before that, and sage before that.
  # Defined after c_plan because jq only sees what is above it. No apostrophes in
  # these comments: the whole jq program sits inside single quotes.
  def c_cost:   c_plan;
  def dot: tint(c_dot; " · ");
  # Meter words (labels and numbers) are GIGA BLUE, the periwinkle of the "!"
  # in BANGARANG!, and the bars GIGA PURPLE (Adam, 2026-09-25: "revert to GIGA
  # BLUE for the txt and percentages", "GIGA PURPLE on the progress bars").
  # The Fable meter too. The limits turn the Meterous amber from 70% and red
  # from 90%; context and cache never do.
  def amber: "\u001b[38;2;224;165;52m";
  def red:   "\u001b[38;2;229;103;91m";
  def purple: "\u001b[38;5;134m";
  def c_text: "\u001b[38;2;114;124;214m";
  def wlevel($base): if . >= 90 then red elif . >= 70 then amber else $base end;
  # Claude status problems in the Pulseous dark palette, bold at worst.
  def tone: {info: "\u001b[38;2;77;155;232m", warn: "\u001b[38;2;251;178;64m", bad: "\u001b[38;2;238;122;80m",
             crit: "\u001b[1;38;2;232;92;92m"}[.] // c_words;
  # Pace: where a window lands by its reset if use carries on at the rate so
  # far. Until $settle seconds have passed, the use so far counts as that whole
  # stretch (a day of a week, half an hour of a 5-hour window), so a busy first
  # few hours do not read as round the clock. Drawn as projected cells only:
  # a window on course to run out simply projects to the end of its bar.
  def forecast($length; $settle):
    if .resets_at == null or .used_percentage == null or .used_percentage >= 100 then null
    else ($now - (.resets_at - $length)) as $elapsed
      | if $elapsed <= 0 or $elapsed >= $length then null
        else (.used_percentage / ([$elapsed, $settle] | max)) as $rate
          | {landing: (.used_percentage + $rate * (.resets_at - $now))}
        end
    end;
  # Every bar is GIGA PURPLE, the violet of the model name and effort (and of
  # "accept edits on" in Claude Code): used cells in that violet, projected
  # cells a lighter tint of it (38% toward white), so the two never blur
  # together; the rest is slate. Warnings live on the words and numbers of the
  # limits, which turn amber and red.
  def c_bar:       "\u001b[38;2;175;135;255m";
  def c_projected: "\u001b[38;2;205;181;255m";
  # A limit meter, as a table cell {label, bar, tail}: the label and number in
  # the "!" blue (amber from 70%, red from 90%) around a ten-cell bar (solid
  # for the use so far, projected cells up to where the pace says it lands, the
  # rest empty). No reset dates or run-out times in words: the refill bar and
  # the projection carry them. A label_colour on the meter (the Fable purple)
  # replaces the blue: its label keeps that colour always, its number warns
  # like the rest. Projected cells are solid too: shade glyphs mix in the
  # background.
  def meter(name; $length; $settle):
    select(.used_percentage != null)
    | (.used_percentage | round) as $p
    | forecast($length; $settle) as $f
    # Cells round up, so any use at all shows as a solid cell.
    | ([($p / 10 | ceil), 10] | min) as $filled
    | (if $f == null then $filled else ([($f.landing / 10 | ceil), 10] | min) end | [., $filled] | max) as $reach
    # (The base is bound first: inside wlevel the input is the number.)
    | (.label_colour // c_text) as $base
    | ($p | wlevel($base)) as $wc
    | {label: tint(.label_colour // $wc; name),
       bar: (tint(c_bar; rep("█"; $filled))
             + (if $f != null then tint(c_projected; rep("█"; $reach - $filled)) else "" end)
             + tint(c_dot; rep("░"; 10 - $reach))),
       tail: tint($wc; "\($p)%")};

  # The prompt cache: Claude keeps the conversation cached for its TTL (an hour
  # on a subscription) after each message; once it lapses, the next reply
  # re-reads the whole context. A bar of the time left and an empty bar once it
  # has gone cold, reading 0% (Adam: "instead of cold put 0%"), with the words
  # always in the "!" blue like context: the bar
  # shows how close it is. Claude Code redraws the line itself the moment it expires.
  # Always there (Adam: "always show the cache"): before the first request of a
  # session Claude Code has no cache to report (it only tracks one once this
  # process has made a request, so a fresh or resumed session starts without
  # it), and a warm cache can lack an expiry time; both show an empty bar and
  # "…", waiting.
  def cache_meter:
    .prompt_cache as $pc
    | {label: tint(c_text; "Cache")} as $cell
    | if $pc == null or ($pc.warm == true and $pc.expires_at == null) then
        $cell + {bar: tint(c_dot; rep("░"; 10)), tail: tint(c_text; "…")}
      else
        ({"1h": 3600, "5m": 300}[$pc.ttl // "1h"] // 3600) as $ttl
        | (if $pc.warm == true then $pc.expires_at else 0 end) as $until
        | ($until - $now) as $left
        | if $left > 0 then
            ([($left / $ttl * 10 | ceil), 10] | min) as $cells
            | $cell + {bar: (tint(c_bar; rep("█"; $cells)) + tint(c_dot; rep("░"; 10 - $cells))),
                       tail: tint(c_text; "\($left / 60 | ceil)m")}
          else $cell + {bar: tint(c_dot; rep("░"; 10)), tail: tint(c_text; "0%")} end
      end;

  # Refill: the time left before the 5-hour window resets and that limit comes
  # back in full. The bar FILLS as the refill nears (Adam: "the progress bar
  # grows as the time nears for refill"): empty just after a reset, one cell
  # per half hour gone; it is the mirror of the time left. Hours from an hour
  # out (rounded), minutes after that.
  def refill_meter:
    .rate_limits.five_hour.resets_at as $r
    | select($r != null)
    | ($r - $now) as $left
    | select($left > 0)
    | (10 - ([($left / 18000 * 10 | ceil), 10] | min) | [., 0] | max) as $cells
    | {label: tint(c_text; "Refill"),
       bar: (tint(c_bar; rep("█"; $cells)) + tint(c_dot; rep("░"; 10 - $cells))),
       # "2hr" rather than "2h": three characters, like the numbers around it.
       tail: tint(c_text; (if $left >= 3600 then "\($left / 3600 | round)hr" else "\($left / 60 | ceil)m" end))};

  # The model (and its context size), the effort and fast mode: the start of
  # row 2, with the plan and the session cost to their right.
  def model_pieces:
    (.model.display_name // .model.id // "unknown model") as $name
    | ($name | hue) as $c
    | (if $c == "" then c_words else "\u001b[\($c)m" end) as $mc
    | ("\u001b[1\(if $c == "" then "" else ";\($c)" end)m\($name)\u001b[0m"
         + (.context_window.context_window_size | if . then " " + tint($mc; "(\(size))") else "" end)),
      # "Effort" spelled out, so "Max Effort" never reads as the Max plan.
      # Effort in the model purple, bold when it is max.
      (if .effort.level then tint(
         (if $c == "" then c_words else "\u001b[\(if .effort.level == "max" then "1;" else "" end)\($c)m" end);
         (.effort.level | if . == "xhigh" then "XHigh" else (.[:1] | ascii_upcase) + .[1:] end) + " Effort") else empty end),
      (if .fast_mode == true then tint(c_fast; "fast") else empty end);

  # Row 1 as table cells (Adam: "move BANGARANG to the top left", then "swap
  # Claude operational with Max 20x and $"): the head is the phrase (flex: it
  # fills the room the row 2 head leaves, and never leaves: "Bangarang can
  # never leave") and the Claude status, whose mark stands where a dot would,
  # over a dot of row 2 when the phrase can reach it (see layout); then the
  # context meter, the refill timer and the cache meter.
  def cells_session($st):
    .context_window.used_percentage as $used
    | [{label: "", bar: "", flex: true, tail: $st.text},
       # The context window as a bar too, laid out like the limit meters:
       # label, ten cells, number. No pace, since it has no reset.
       (if $used != null then
          ([($used / 10 | ceil), 10] | min) as $cells
          # Always the "!" blue, even nearly full: the bar shows how full it is.
          | {label: tint(c_text; "Context"),
             bar: (tint(c_bar; rep("█"; $cells)) + tint(c_dot; rep("░"; 10 - $cells))),
             tail: tint(c_text; "\($used)%")}
        else empty end),
       # This order puts labels of the same length in each column (context over
       # session, refill over weekly, cache over Fable), so nothing needs padding.
       refill_meter,
       cache_meter];

  # Always on, like the Pulseous badge, so "all clear" never looks like "not
  # running": all clear in a calm sage green (c_ok), softer than the Meterous
  # colours and turned cool of pure green, because greens that lean yellow at
  # this softness read as olive and sickly. Else the problem.
  # A verdict counts for 20 minutes (STALE_MS in Pulseous). An older one still
  # shows for the few seconds a fresh check is under way; after that, or if the
  # check failed, the status is "?". No apostrophes in here: this jq program
  # sits inside single quotes.
  def service:
    ($status | try fromjson catch null | if type == "object" then . else null end) as $s
    | ($failed != "1" and $now - $checked < 15) as $checking
    | if $s != null and ($now - ($s.at // 0) <= 1200 or $checking) then
        (if ($s.tone // "ok") == "ok" or ($s.text // "") == "" then
           {ok: true, text: tint(c_ok; "✓ Claude operational")}
         # A problem is just "Claude Outage" (maintenance says so), in the colour
         # of how bad it is, so BANGARANG always keeps its room (Adam: "just call
         # it a Claude Outage so Bangarang stays").
         else {ok: false, text: tint($s.tone | tone; if $s.tone == "info" then "✕ Claude Maintenance" else "✕ Claude Outage" end)} end)
      elif $checking then {ok: false, text: tint(c_words; "checking Claude status…")}
      else {ok: false, text: tint("warn" | tone; "? Claude status unknown")} end;

  # The per-model weekly meters (Fable and so on), from the headless /usage
  # report. They share the weekly window, so their pace and reset use the
  # weekly resets_at. Shown while the report is under 30 minutes old; after a
  # failed refresh the last known names get a "?" instead.
  def scoped_meters:
    ($usage | try fromjson catch null | if type == "object" then . else null end) as $u
    | .rate_limits.seven_day.resets_at as $reset
    | if $u == null then empty
      elif $now - ($u.at // 0) <= 1800 then
        (($u.scoped // [])[]
         | {label: .name, used_percentage: .percent, resets_at: $reset}
         | meter(.label; 604800; 86400))
      elif $usage_failed == "1" then (($u.scoped // [])[] | {label: "", bar: "", tail: tint(c_text; .name + " ?")})
      else empty end;

  # Row 2 as table cells: the model, effort and fast mode, then the plan and
  # the session cost, then the limits.
  def cells_plan($st):
    # Pace counts early use as a full half hour of a 5-hour window, a full day of a week.
    [{label: "", bar: "", tail: ([model_pieces,
                                  (if $plan != "" then tint(c_plan; $plan) else empty end),
                                  (if (.cost.total_cost_usd // 0) > 0 then tint(c_cost; .cost.total_cost_usd | dollars) else empty end)]
                                 | join(dot))},
       # "Session", as claude.ai names the 5-hour limit ("Current session").
       # Every bar label starts with a capital, like Fable (Adam asked).
       (.rate_limits.five_hour | meter("Session"; 18000; 1800)),
       (.rate_limits.seven_day | meter("Weekly"; 604800; 86400)),
       scoped_meters];

  # The phrase, top left of row 1: BANGARANG, the word Adam shouted when the
  # bars first landed, or your own ($word, from --phrase). Bold, in a clay, rose,
  # purple and blue gradient (the palette of the whole line). Built to fill its
  # room exactly, so the spacing around it stays even: letter-spaced once there
  # is room for that, an exclamation mark for an odd leftover, then chevrons, up
  # to four a side, then hearts outside them, spaced like the letters
  # ("♥ ♥ »»» B A N G A R A N G ««« ♥ ♥"), as far as the room goes. Three
  # chevrons or four, whichever makes the hearts fit.
  def phrase($w):
    ($word | length) as $n
    | ($word | explode | map([.] | implode) | join(" ")) as $spaced
    | if $w < $n then null
    else (if $w >= ($spaced | length) then $spaced else $word end) as $core
      | ($w - ($core | length)) as $e
      | (if $e % 2 == 1 then $core + "!" else $core end) as $c
      | ($e - $e % 2) as $even
      | ($even / 2) as $side
      | if $even == 0 then $c
        elif $even == 2 then $c + "!!"
        else (if $side <= 4 then $side - 1 else 3 + ($side - 4) % 2 end) as $k
          | (($side - 1 - $k) / 2) as $h
          | rep("♥ "; $h) + rep("»"; $k) + " " + $c + " " + rep("«"; $k) + rep(" ♥"; $h)
        end
    end;
  def shade($t):
    [[215,135,95],[232,142,144],[175,95,215],[89,136,213]] as $s
    | ($t * 3) as $x | ([($x | floor), 2] | min) as $k | ($x - $k) as $u
    | [range(0; 3) as $j | ($s[$k][$j] + ($s[$k + 1][$j] - $s[$k][$j]) * $u | round)];
  def rainbow:
    length as $n
    | [range(0; $n) as $i | .[$i:$i + 1] as $ch
       | if $ch == " " then " "
         else ($i / ([$n - 1, 1] | max) | shade($i / ([$n - 1, 1] | max))) as $c
           | "\u001b[1;38;2;\($c[0]);\($c[1]);\($c[2])m" + $ch + "\u001b[0m" end]
    | join("");

  # The box round the rows is drawn in a soft rainbow from red round to violet,
  # left to right: OKLCH lightness 0.76, chroma 0.12, hue 25 to 320 in twelve
  # stops, blended between. $t runs from 0 (left edge) to 1 (right edge); $n
  # adds to the blue (the minute nudge below).
  def rainbow_rgb($t; $n):
    [[244,146,138],[237,154,103],[218,167,80],[188,181,84],[148,193,111],[102,200,149],
     [57,201,188],[56,197,222],[98,187,245],[142,175,254],[180,162,246],[211,152,224]] as $s
    | ($s | length - 1) as $m | ($t * $m) as $x
    | ([($x | floor), $m - 1] | min) as $k | ($x - $k) as $u
    | "\u001b[38;2;" + ([range(0; 3) as $j
                         | ($s[$k][$j] + ($s[$k + 1][$j] - $s[$k][$j]) * $u | round) + (if $j == 2 then $n else 0 end)
                         | [., 255] | min | tostring] | join(";")) + "m";

  # Both rows as a table. Each column is as wide as its widest cell; labels are
  # padded so the bars start together (rarely needed: each column pairs labels
  # of the same length); in the last column the numbers are
  # right-aligned (when they differ by 6 or less), so both rows end on the same
  # column. The flex head fills its spare room exactly with the phrase, and
  # always has room for at least the shortest one. A head with no phrase that
  # would need more than 22 spaces of padding (row 2 with next to nothing in
  # it) leaves the rows unaligned instead, rather than open a wide gap; the
  # phrase still shows there, at a set size.
  def bare: gsub("\u001b\\[[0-9;]*m"; "");
  def visible: bare | length;
  def is_meter: .bar != "";
  # The status mark (✓, ✕ or ?) stands where the dot after the phrase would be,
  # a bullet for the status (Adam: "move the checkmark"); a status without one
  # ("checking Claude status…") keeps the dot. flex_sep is what joins them.
  def flex_sep: if .tail | bare | test("^[✓✕?] ") then " " else dot end;
  def cell_width($lw; $pw):
    if is_meter then $lw + 12 + (.tail | visible)
    elif .flex == true then (.tail | visible) + $pw + (if .tail == "" then 0 else flex_sep | visible end)
    else (.tail | visible) end;
  def render_cell($d):
    (if is_meter then
       (.tail | visible) as $t
       | (if $d.last and ($d.tw - $t) <= 6 then rep(" "; $d.tw - $t) else "" end) as $lead
       | .label + rep(" "; $d.lw - (.label | visible)) + " " + .bar + " " + $lead + .tail
     elif .flex == true then
       flex_sep as $sep
       | phrase(if .tail == "" then $d.w else $d.w - (.tail | visible) - ($sep | visible) end) as $p
       | if $p == null then .tail elif .tail == "" then ($p | rainbow) else ($p | rainbow) + $sep + .tail end
     else .tail end)
    | . + rep(" "; $d.w - visible);
  def layout:
    . as $rows
    | ([$rows[] | length] | max) as $n
    # The phrase reaches to a dot in the head of row 2 when it can, so the
    # status mark stands right over that dot (Adam: "line up with the Max x20
    # dot"; for him the dot before Max 20x, once a session passes $10): the dot
    # that leaves row 2 the least to pad, two spaces at most. Row 1 never pads,
    # since the phrase can fill any room. $pw is the room the phrase keeps: that
    # reach, else the shortest phrase, which then fills what row 2 leaves.
    | [$rows[] | .[0] | select(. != null and .flex != true) | .tail | bare] as $heads
    | ([$heads[] | length] | max // 0) as $hw
    | ([$rows[] | .[0] | select(. != null and .flex == true)] | first) as $f
    | (if $f == null or $f.tail == "" then null
       else (($f | flex_sep | visible) + ($f.tail | visible)) as $rest
         | [$heads[] | explode | to_entries[] | select(.value == 183) | .key - 1
            | select(. >= ($word | length)) | {p: ., slack: (. + $rest - $hw)}
            | select(.slack >= 0 and .slack <= 2)]
         | min_by(.slack) | .p
       end) as $reach
    | ($reach // ($word | length)) as $pw
    | [range(0; $n) as $i
       | [$rows[] | .[$i] | select(. != null)] as $col
       | ([$col[] | select(is_meter) | .label | visible] | max // 0) as $lw
       | {lw: $lw,
          tw: ([$col[] | select(is_meter) | .tail | visible] | max // 0),
          last: ($i == $n - 1),
          w: ([$col[] | cell_width($lw; $pw)] | max)}] as $dims
    # (a flex head counts with the room it keeps for the phrase, as in cell_width)
    | ([$rows[] | .[0] | select(. != null) | cell_width(0; $pw)] | max // 0) as $head
    | if any($rows[] | .[0] | select(. != null and .flex != true); $head - (.tail | visible) > 22) then
        [$rows[] | [.[] | if is_meter then .label + " " + .bar + " " + .tail
                          elif .flex == true then ("» " + ($word | explode | map([.] | implode) | join(" ")) + " «" | rainbow) + (if .tail == "" then "" else flex_sep + .tail end)
                          else .tail end] | join(dot)]
      else
        [$rows[] | . as $row | [range(0; length) as $i | $row[$i] | render_cell($dims[$i])] | join(dot) | sub(" +$"; "")]
      end;

  # A rainbow box round the rows (Adam: "a box of hearts around everything",
  # then "a full box instead of hearts, rainbow coloured"): rounded corners, a
  # rule along the top and bottom in the rainbow, and a side line a space off
  # each end of every row, the rows padded to the widest so the right side
  # runs straight (even when the rows are unaligned inside). The
  # sides take the colours of the corners above them. SF Mono has all the
  # box-drawing glyphs, and its vertical line runs past the top and bottom of
  # the line, so the sides join up. The rules carry one reset at the end:
  # Claude Code repeats every colour code of the lines above at the start of
  # each line, so the top rule rides along on every line.
  # The box colours step one unit of blue on odd minutes. Claude Code only
  # rewrites cells that changed, and Terminal.app can leave a row it has not
  # been sent in a while blank (after the window was hidden, 2026-09-23: the
  # rules vanished while the busy rows between them stayed), so an unchanging
  # box would never come back. The nudge is invisible and makes every refresh
  # repaint it.
  service as $st
  | [cells_session($st), cells_plan($st)] | layout | map(select(. != ""))
  | if length > 0 then
      ((map(visible) | max) + 4) as $bw
      | (($now / 60 | floor) % 2) as $nudge
      | [range(0; $bw) as $i | rainbow_rgb($i / ($bw - 1); $nudge)] as $c
      | ([range(0; $bw) as $i | $c[$i] + (if $i == 0 then "╭" elif $i == $bw - 1 then "╮" else "─" end)] | join("") + "\u001b[0m") as $top
      | ([range(0; $bw) as $i | $c[$i] + (if $i == 0 then "╰" elif $i == $bw - 1 then "╯" else "─" end)] | join("") + "\u001b[0m") as $bottom
      | [$top] + map($c[0] + "│\u001b[0m " + . + rep(" "; $bw - 3 - visible) + $c[$bw - 1] + "│\u001b[0m") + [$bottom]
    else . end
  | join("\n")
'
