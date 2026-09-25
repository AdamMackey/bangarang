#!/bin/bash
# Tests for the new status line. Every run uses a throwaway HOME, so the real
# cache (~/Library/Caches or ~/.cache, claude-statusline) is never touched.
# Runs on macOS and Linux.
here=$(cd "$(dirname "$0")" && pwd)
new=$(cd "$here/.." && pwd)/statusline.sh
fx=$here/fixtures
T=$(mktemp -d "${TMPDIR:-/tmp}/bangarang-tests.XXXX")
unset XDG_CACHE_HOME
# where the script keeps its cache under a given HOME, as it decides it
cachedir() { if [ "$(uname)" = Darwin ]; then echo "$1/Library/Caches/claude-statusline"; else echo "$1/.cache/claude-statusline"; fi; }
# an epoch time in a date format: BSD date takes -r, GNU date -d @
epochfmt() { date -r "$1" "+$2" 2>/dev/null || date -d "@$1" "+$2"; }
trap 'rm -rf "$T"' EXIT
now=$(date +%s)
pass=0; fail=0
plain() { sed $'s/\e\\[[0-9;]*m//g' | tr -s ' '; }   # squeezes the table padding
check() { # name, expected, actual
  if [ "$2" == "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fi
}

# ---- the background status check, with a fake curl ----
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
[ -n "$FAKE_CURL_FAIL" ] && exit 22
cat "$FAKE_SUMMARY"
EOF
chmod +x "$T/bin/curl"
cat > "$T/bin/claude" <<'EOF2'
#!/bin/bash
[ -n "$FAKE_CLAUDE_FAIL" ] && exit 1
cat "$FAKE_USAGE"
EOF2
chmod +x "$T/bin/claude"
fh="$T/home-fetch"; fc=$(cachedir "$fh")
fetch() { HOME="$fh" PATH="$T/bin:$PATH" FAKE_SUMMARY="$fx/$1" FAKE_CURL_FAIL="$2" bash "$new" --fetch-status; }
verdict() { jq -c '{tone, text}' "$fc/status.json"; }

fetch ok.json;            check "fetch: all clear"        '{"tone":"ok","text":""}' "$(verdict)"
check "fetch: stamps the time" "yes" "$(jq --argjson n "$now" 'if (.at - $n) | fabs < 5 then "yes" else "no" end' -r "$fc/status.json")"
fetch code-degraded.json; check "fetch: Claude Code degraded" '{"tone":"warn","text":"Claude Code degraded"}' "$(verdict)"
fetch multi.json;         check "fetch: four services, relevant first" '{"tone":"crit","text":"Claude Code degraded, Claude API partial outage, claude.ai major outage +1 more"}' "$(verdict)"
fetch incident-only.json; check "fetch: incident before components move" '{"tone":"warn","text":"Elevated errors on Claude Opus 5.5"}' "$(verdict)"
fetch maintenance.json;   check "fetch: maintenance" '{"tone":"info","text":"Claude API under maintenance"}' "$(verdict)"
fetch group-row.json;     check "fetch: group rows ignored" '{"tone":"ok","text":""}' "$(verdict)"
fetch odd-state.json;     check "fetch: unknown state counts as amber" '{"tone":"warn","text":"Claude Cowork investigating weird"}' "$(verdict)"
fetch long-incident.json; check "fetch: long incident clipped" '{"tone":"bad","text":"Claude Code sessions are failing to start for some users on…"}' "$(verdict)"
fetch code-degraded.json
fetch html.json
check "fetch: HTML keeps last verdict" '{"tone":"warn","text":"Claude Code degraded"}' "$(verdict)"
check "fetch: HTML marks failure" "yes" "$([ -e "$fc/status-failed" ] && echo yes || echo no)"
fetch ok.json 1
check "fetch: network failure keeps verdict" '{"tone":"warn","text":"Claude Code degraded"}' "$(verdict)"
fetch ok.json
check "fetch: success clears failure mark" "no" "$([ -e "$fc/status-failed" ] && echo yes || echo no)"
check "fetch: no temp files left" "none" "$(ls "$fc" | grep -q '\.json\.' && echo leftovers || echo none)"

# ---- the headless /usage, with a fake claude ----
fetchu() { HOME="$fh" PATH="$T/bin:$PATH" FAKE_USAGE="$fx/$1" FAKE_CLAUDE_FAIL="$2" bash "$new" --fetch-usage; }
fetchu usage-ok.json
check "usage: Fable row parsed"      '[{"name":"Fable","percent":2}]' "$(jq -c .scoped "$fc/usage.json")"
check "usage: stamps the time"       "yes" "$(jq --argjson n "$now" 'if (.at - $n) | fabs < 5 then "yes" else "no" end' -r "$fc/usage.json")"
fetchu usage-nologin.json
check "usage: no report keeps the last answer" '[{"name":"Fable","percent":2}]' "$(jq -c .scoped "$fc/usage.json")"
check "usage: no report marks failure" "yes" "$([ -e "$fc/usage-failed" ] && echo yes || echo no)"
fetchu usage-ok.json 1
check "usage: claude failing keeps the answer" '[{"name":"Fable","percent":2}]' "$(jq -c .scoped "$fc/usage.json")"
fetchu usage-ok.json
check "usage: success clears the failure mark" "no" "$([ -e "$fc/usage-failed" ] && echo yes || echo no)"
check "usage: no temp files left"    "none" "$(ls "$fc" | grep -q 'usage\.json\.' && echo leftovers || echo none)"

# ---- the status line itself ----
dh="$T/home-display"; dc=$(cachedir "$dh"); mkdir -p "$dc"
# status: fresh ok | fresh <tone>:<text> | stale | stale-failed | corrupt | none
seed() {
  rm -f "$dc"/status*; touch "$dc/status-checked" "$dc/usage-checked"   # fresh stamps: no background checks during tests
  case "$1" in
    ok)           jq -n --argjson at "$now" '{at: $at, tone: "ok", text: ""}' > "$dc/status.json" ;;
    stale)        jq -n --argjson at $((now - 3600)) '{at: $at, tone: "warn", text: "Claude Code degraded"}' > "$dc/status.json" ;;
    stale-failed) jq -n --argjson at $((now - 3600)) '{at: $at, tone: "warn", text: "Claude Code degraded"}' > "$dc/status.json"; touch "$dc/status-failed" ;;
    corrupt)      printf '{"at": 12' > "$dc/status.json" ;;
    none)         ;;
    *:*)          jq -n --argjson at "$now" --arg t "${1%%:*}" --arg x "${1#*:}" '{at: $at, tone: $t, text: $x}' > "$dc/status.json" ;;
  esac
}
# payload with limits: five_hour pct, minutes to reset; seven_day pct, minutes to reset ("-" = leave out)
payload() {
  jq -c --argjson now "$now" --arg f "$1" --arg fm "$2" --arg w "$3" --arg wm "$4" '
    .rate_limits = ({}
      + (if $f == "-" then {} else {five_hour: {used_percentage: ($f|tonumber), resets_at: ($now + ($fm|tonumber) * 60)}} end)
      + (if $w == "-" then {} else {seven_day: {used_percentage: ($w|tonumber), resets_at: ($now + ($wm|tonumber) * 60)}} end))
    | if .rate_limits == {} then del(.rate_limits) else . end' "$here/base.json"
}
# The status line reads the clock with `date +%s`; pin it to the test's own clock
# so exact pace boundaries do not drift by the seconds a run takes.
mkdir -p "$T/datebin"
printf '#!/bin/bash\nif [ "$1" = "+%%s" ] && [ -n "$FAKE_NOW" ]; then echo "$FAKE_NOW"; else exec /bin/date "$@"; fi\n' > "$T/datebin/date"
chmod +x "$T/datebin/date"
# (--usage: the per-model limits are opt-in, and most checks want them; see "usage:" below)
runfull() { HOME="$dh" PATH="$T/datebin:$PATH" FAKE_NOW="$now" bash "$new" --usage; }
# The rows sit in a rainbow box: a rule above and below, a side line a space off each end of every
# row. Most checks look inside the box (row 1 is line 1); the box has its own checks.
# (the box colours step one unit of blue on odd minutes, so match any colour on the sides)
unbox() { sed '1d;$d' | sed -E $'s/^\e\\[38;2;[0-9;]*m│\e\\[0m //; s/ *\e\\[38;2;[0-9;]*m│\e\\[0m$//'; }
run() { runfull | unbox; }
nobar() { sed -E 's/[██░]{10} //g'; }
# Row 1 is the phrase and the Claude status, then Context, Refill and Cache; row 2 the model, effort,
# fast mode, plan and cost, then Session, Weekly and Fable. Most checks read "status · limits"
# together (the status from row 1, the limits from row 2), the way one row used to show them.
nophrase1() { sed -E 's/^(♥ )*(»+ )?(B A N G A R A N G|BANGARANG)!*( «+)?( ♥)*( · )?//'; }
statuslimits() { local o st li; o=$(cat)
  st=$(printf '%s\n' "$o" | sed -n 1p | nophrase1 | sed -E 's/ · (Context|Refill|Cache) .*$//; s/ +$//')
  li=$(printf '%s\n' "$o" | sed -n 2p | perl -ne 'print $1 if /^.*? · ((?:Session|Weekly|Fable)[ ?].*)$/')
  if [ -n "$li" ]; then echo "$st · $li"; else echo "$st"; fi; }
row2() { run | plain | nobar | statuslimits; }
row2bars() { run | plain | statuslimits; }
# The head of row 2: model, effort, fast mode, plan and cost.
head2() { run | plain | sed -n 2p | perl -pe 's/ · (?:Session|Weekly|Fable)[ ?].*$//'; }
acct() { printf '{"numStartups":3,"oauthAccount":{"emailAddress":"x@example.com","organizationType":"%s","organizationRateLimitTier":%s}}' "$1" "$2" > "$dh/.claude.json"; }
aged() { touch -t "$(epochfmt $((now - 60)) %Y%m%d%H%M.%S)" "$dc/plan"; }   # the cached answer is a minute old

OK='✓ Claude operational · '
# A time the way the script words it from a day out: weekday (plus date from six days), hour, minutes unless :00, am/pm.
fmt() { epochfmt "$1" "$2 %l:%M%p" | tr -s ' ' | sed 's/:00\([AP]M\)$/\1/; s/AM$/am/; s/PM$/pm/'; }

seed ok
# pace: session windows are 300 minutes, weeks 10080; landing = used x window / elapsed
check "pace blue: half the window, 20% used lands 40%" "${OK}Session ████░░░░░░ 20% · Weekly ██████░░░░ 30%" "$(payload 20 150 30 5040 | row2bars)"
check "pace amber from 90%" "${OK}Session █████████░ 45%" "$(payload 45 150 - 0 | row2bars)"
check "pace red says when it runs out"                   "${OK}Session 60%"           "$(payload 60 150 - 0 | row2)"
check "early session: use so far counts as half an hour" "${OK}Session ███░░░░░░░ 2%" "$(payload 2 285 - 0 | row2bars)"
check "early heavy burst still warns"                    "${OK}Session 50%"              "$(payload 50 285 - 0 | row2)"
check "first day of a week counts as a whole day" "${OK}Weekly █████████░ 12%" "$(payload - 0 12 9000 | row2bars)"
check "today: 5% six hours into the week lands at 38%" "${OK}Weekly ████░░░░░░ 5%" "$(payload - 0 5 9720 | row2bars)"
check "weekly run-out a day or more away: weekday"       "${OK}Weekly 60%" "$(payload - 0 60 5040 | row2)"
check "amber meter: pace, then reset"                    "${OK}Session 4% · Weekly 83%" "$(payload 4 230 83 950 | row2)"
check "red meter near the end"                           "${OK}Session 95% · Weekly 12%" "$(payload 95.4 42 12 7000 | row2)"
check "limit reached: no pace, just the reset"           "${OK}Session 100% · Weekly 12%" "$(payload 100 65 12 7000 | row2)"
check "reset days away: weekday only"                    "${OK}Weekly 75%" "$(payload - 0 75 4320 | row2)"
check "reset six days or more away: date too"            "${OK}Weekly 75%" "$(payload - 0 75 9000 | row2)"
check "no limits: the tick alone"                        "✓ Claude operational"                      "$(payload - 0 - 0 | row2)"
touch "$dc/status-failed"
check "fresh verdict survives a blip"                    "${OK}Session 4% · Weekly 12%"   "$(payload 4 230 12 7000 | row2)"

LIM='Session 4% · Weekly 12%'
seed "warn:Claude Code degraded"
check "an outage is just Claude Outage" "✕ Claude Outage · $LIM"           "$(payload 4 230 12 7000 | row2)"
check "outage alone when no limits"  "✕ Claude Outage"                  "$(payload - 0 - 0 | row2)"
settle() { touch -t "$(epochfmt $((now - 30)) %Y%m%d%H%M.%S)" "$dc/status-checked"; }   # the last check started 30s ago
seed stale-failed
check "stale and failing: unknown"   "? Claude status unknown · $LIM"          "$(payload 4 230 12 7000 | row2)"
seed stale
check "stale while a check runs: last verdict" "✕ Claude Outage · $LIM" "$(payload 4 230 12 7000 | row2)"
settle
check "stale, check never answered: unknown" "? Claude status unknown · $LIM"  "$(payload 4 230 12 7000 | row2)"
seed corrupt
check "corrupt verdict, check running" "checking Claude status… · $LIM"        "$(payload 4 230 12 7000 | row2)"
settle
check "corrupt verdict, check done: unknown" "? Claude status unknown · $LIM"  "$(payload 4 230 12 7000 | row2)"
seed none
check "first check running"          "checking Claude status… · $LIM"          "$(payload 4 230 12 7000 | row2)"
settle
check "no verdict ever: unknown"     "? Claude status unknown · $LIM"          "$(payload 4 230 12 7000 | row2)"

# bars: ten cells, solid for use, shaded to where the pace lands, empty after
raw2() { run | sed -n 2p; }; has() { grep -q "$1" && echo yes || echo no; }
seedu() { rm -f "$dc"/usage*; touch "$dc/usage-checked"; case "$1" in
  fresh) jq -n --argjson at "$now" '{at: $at, scoped: [{name: "Fable", percent: 2}]}' > "$dc/usage.json" ;;
  stale) jq -n --argjson at $((now - 3600)) '{at: $at, scoped: [{name: "Fable", percent: 2}]}' > "$dc/usage.json" ;;
  hot) jq -n --argjson at "$now" '{at: $at, scoped: [{name: "Fable", percent: 75}]}' > "$dc/usage.json" ;;
  corrupt) printf '{"at": 1' > "$dc/usage.json" ;;
  none) ;; esac; }
seed ok
check "bar: 4% rounds up to 1 cell, landing 17% to 2" "${OK}Session ██░░░░░░░░ 4% · Weekly ████░░░░░░ 12%" "$(payload 4 230 12 7000 | row2bars)"
check "bar: running out shades to the end"  "${OK}Session ██████████ 60%"  "$(payload 60 150 - 0 | row2bars)"
check "bar: full at 100%" "${OK}Session ██████████ 100% · Weekly ████░░░░░░ 12%" "$(payload 100 65 12 7000 | row2bars)"
check "bar: running out early shades the rest" "${OK}Weekly ██████████ 75%" "$(payload - 0 75 9000 | row2bars)"
check "bar: no pace, solid cells only" "${OK}Fable █░░░░░░░░░ 2%" "$(seedu fresh; payload - 0 - 0 | row2bars; seedu none)"
check "bar cells: used purple, projected light purple, rest slate" "yes" "$(payload 4 230 12 7000 | raw2 | has $'\e\\[38;2;175;135;255m█\e\\[0m\e\\[38;2;205;181;255m█\e\\[0m\e\\[38;2;98;106;133m░░░░░░░░\e\\[0m \e\\[38;2;114;124;214m4%')"
check "bar cells: running out projects in purple"   "yes" "$(payload 60 150 - 0 | raw2 | has $'\e\\[38;2;175;135;255m██████\e\\[0m\e\\[38;2;205;181;255m████\e\\[0m')"

# every bar is blue, whatever the level: warnings live on the words and numbers
check "bars stay purple at 83%"          "yes" "$(payload 4 230 83 950 | raw2 | has "${G}█████████"$'\e\\[0m')"
check "bars stay purple at 95%"          "yes" "$(payload 95 42 12 7000 | raw2 | has "${G}██████████"$'\e\\[0m')"
check "number still amber at 83%"      "yes" "$(payload 4 230 83 950 | raw2 | has "${A}83%")"

# the Fable meter from the cached /usage report
raw2() { run | sed -n 2p; }; has() { grep -q "$1" && echo yes || echo no; }
seed ok; seedu fresh
check "Fable meter with its own pace" "${OK}Session ██░░░░░░░░ 4% · Weekly ████░░░░░░ 12% · Fable █░░░░░░░░░ 2%" "$(payload 4 230 12 7000 | row2bars)"
check "Fable label and number in GIGA BLUE"  "yes" "$(payload 4 230 12 7000 | raw2 | has $'\e\\[38;2;114;124;214mFable\e\\[0m .*\e\\[38;2;114;124;214m2%')"
check "Fable without a weekly window: just the number" "${OK}Fable 2%" "$(payload - 0 - 0 | row2)"
check "Fable no longer purple"      "no" "$(payload 4 230 12 7000 | raw2 | has $'\e\\[38;5;134mFable')"
seedu hot
check "Fable at 75%: label and number amber, like weekly" "yes" "$(payload 4 230 12 7000 | raw2 | has $'\e\\[38;2;224;165;52mFable\e\\[0m .*\e\\[38;2;224;165;52m75%')"
seedu stale
check "stale report, refresh under way: quiet" "${OK}$LIM" "$(payload 4 230 12 7000 | row2)"
touch "$dc/usage-failed"
check "stale report after a failed refresh: ?" "${OK}$LIM · Fable ?" "$(payload 4 230 12 7000 | row2)"
check "Fable ? in GIGA BLUE" "yes" "$(payload 4 230 12 7000 | raw2 | has $'\e\\[38;2;114;124;214mFable ?')"
seedu corrupt
check "corrupt report: quiet"             "${OK}$LIM" "$(payload 4 230 12 7000 | row2)"
seedu none; touch "$dc/usage-failed"
check "no report ever, failed: quiet"     "${OK}$LIM" "$(payload 4 230 12 7000 | row2)"
seedu none
# the per-model limits are opt-in: a headless claude every ten minutes is for the user to choose
bare() { HOME="$dh" PATH="$T/datebin:$PATH" FAKE_NOW="$now" bash "$new"; }
seedu fresh
check "usage: off by default, no Fable meter"      "0" "$(payload 4 230 12 7000 | bare | grep -c Fable)"
check "usage: --usage turns it on"                 "1" "$(payload 4 230 12 7000 | run | grep -c Fable)"
check "usage: so does BANGARANG_USAGE=1"           "1" "$(payload 4 230 12 7000 | HOME="$dh" PATH="$T/datebin:$PATH" FAKE_NOW="$now" BANGARANG_USAGE=1 bash "$new" | grep -c Fable)"
rm -f "$dc"/usage*
check "usage: off, no background claude is started" "untouched" "$(payload 4 230 12 7000 | bare >/dev/null; [ -e "$dc/usage-checked" ] && echo touched || echo untouched)"
seedu none

# colours: meter words in the "!" blue, amber from 70, red from 90; model and effort Fable purple
seed ok
raw2() { run | sed -n 2p; }
has() { grep -q "$1" && echo yes || echo no; }
B=$'\e\\[38;2;89;136;213m'; P=$'\e\\[38;5;134m'; U=$'\e\\[38;2;114;124;214m'; G=$'\e\\[38;2;175;135;255m'; A=$'\e\\[38;2;224;165;52m'; R=$'\e\\[38;2;229;103;91m'
check "blue number below 70"         "yes" "$(payload 4 230 12 7000 | raw2 | has "${U}4%")"
check "amber number from 70"         "yes" "$(payload 4 230 83 950 | raw2 | has "${A}83%")"
check "red number from 90"           "yes" "$(payload 95 42 12 7000 | raw2 | has "${R}95%")"
check "meter label in GIGA BLUE"   "yes" "$(payload 4 230 12 7000 | raw2 | has $'\e\\[38;2;114;124;214mSession\e\\[0m')"
check "no purple on session or weekly" "no" "$(payload 4 230 12 7000 | raw2 | has "${P}Session\|${P}Weekly\|${P}4%\|${P}12%")"
check "amber label at 83%"      "yes" "$(payload 4 230 83 950 | raw2 | has "${A}Weekly")"
check "projected light purple cells at a 90% landing" "yes" "$(payload 45 150 - 0 | raw2 | has $'\e\\[38;2;205;181;255m████')"
check "slate dots between pieces"    "yes" "$(payload 4 230 12 7000 | raw2 | has $'\e\\[38;2;98;106;133m · \e\\[0m')"
row1() { run | sed -n 1p; }
check "context stays blue at 75%"   "yes" "$(echo '{"model":{"display_name":"Opus 5.5"},"context_window":{"used_percentage":75,"context_window_size":1000000}}' | row1 | has "${U}75%")"
check "context stays blue at 95%"    "yes" "$(echo '{"model":{"display_name":"Opus 5.5"},"context_window":{"used_percentage":95,"context_window_size":1000000}}' | row1 | has "${U}Context"$'\e\\[0m'" .*${U}95%")"
check "context blue below 70"          "yes" "$(row1 < "$here/base.json" | has "${U}7%")"
check "refill words blue"             "yes" "$(payload 4 230 12 7000 | row1 | has "${U}Refill")"
check "model purple for Opus too"       "yes" "$(raw2 < "$here/base.json" | has $'\e\\[1;38;2;175;135;255mOpus 5')"
check "context word blue"        "yes" "$(row1 < "$here/base.json" | has $'\e\\[38;2;114;124;214mContext\e\\[0m')"
check "model and (1M) purple on Sonnet too" "yes" "$(echo '{"model":{"display_name":"Sonnet 5"},"context_window":{"context_window_size":1000000}}' | raw2 | has $'\e\\[1;38;2;175;135;255mSonnet 5\e\\[0m \e\\[38;2;175;135;255m(1M)')"
check "XHigh Effort purple, not bold, on Haiku" "yes" "$(echo '{"model":{"display_name":"Haiku 4.5"},"effort":{"level":"xhigh"}}' | raw2 | has $'\e\\[38;2;175;135;255mXHigh Effort')"
check "context bar: 43% is 4 cells" "Context █████░░░░░ 43%" "$(echo '{"model":{"display_name":"Opus 5.5"},"context_window":{"used_percentage":43,"context_window_size":1000000}}' | row1 | plain | grep -o 'Context [█░]* [0-9]*%')"
check "context bar cells: used purple, rest slate" "yes" "$(row1 < "$here/base.json" | has $'\e\\[38;2;175;135;255m█\e\\[0m\e\\[38;2;98;106;133m░░░░░░░░░\e\\[0m \e\\[38;2;114;124;214m7%')"
check "Max Effort in GIGA PURPLE, bold, even on Opus"  "yes" "$(raw2 < "$here/base.json" | has $'\e\\[1;38;2;175;135;255mMax Effort\e\\[0m')"
# the prompt cache on row 1: time left as a bar, words always the "!" blue, 0% when lapsed
pc() { jq -c --argjson now "$now" --arg w "$1" --arg ttl "$2" --arg left "$3" '.prompt_cache = {warm: ($w == "true"), ttl: $ttl, expires_at: (if $left == "null" then null else $now + ($left|tonumber) end)}' "$here/base.json"; }
C=$'\e\\[38;2;128;175;177m'
check "cache: 58m left is a full cyan bar"   "✓ Claude operational · Context █░░░░░░░░░ 7% · Cache ██████████ 58m" "$(pc true 1h 3480 | row1 | plain | nophrase1)"
check "cache: 30m left is half a bar"        "Cache █████░░░░░ 30m" "$(pc true 1h 1800 | row1 | plain | grep -o 'Cache [█░]* [0-9]*m')"
check "cache: under 10m stays blue"         "yes" "$(pc true 1h 480 | row1 | has "${U}Cache")"
check "cache: never amber"                   "no" "$(pc true 1h 480 | row1 | has "${A}")"
check "cache: 8m left shows 2 cells"         "Cache ██░░░░░░░░ 8m" "$(pc true 1h 480 | row1 | plain | grep -o 'Cache [█░]* [0-9]*m')"
check "cache: warm label is blue"            "yes" "$(pc true 1h 3480 | row1 | has "${U}Cache")"
check "cache: 0% when not warm"              "Cache ░░░░░░░░░░ 0%" "$(pc false 1h 3000 | row1 | plain | grep -o 'Cache [░]* *0%')"
check "cache: 0% once the expiry passes"     "Cache ░░░░░░░░░░ 0%" "$(pc true 1h -60 | row1 | plain | grep -o 'Cache [░]* *0%')"
check "cache: 0% is blue"                    "yes" "$(pc false 1h 0 | row1 | has "${U}0%")"
check "cache: no cold wording left"          "0" "$(pc false 1h 0 | row1 | plain | grep -c cold)"
check "cache: a 5-minute cache scales"       "Cache ████████░░ 4m" "$(pc true 5m 240 | row1 | plain | grep -o 'Cache [█░]* [0-9]*m')"
check "cache: warm with no expiry waits"    "Cache ░░░░░░░░░░ …" "$(pc true 1h null | row1 | plain | grep -o 'Cache [░]* …')"
check "cache: always there, waiting before the first reply" "Cache ░░░░░░░░░░ …" "$(row1 < "$here/base.json" | plain | grep -o 'Cache [░]* …')"
check "cache: the wait is in GIGA BLUE, the bar slate" "yes" "$(row1 < "$here/base.json" | has $'\e\\[38;2;114;124;214mCache\e\\[0m .*\e\\[38;2;98;106;133m░░░░░░░░░░\e\\[0m *\e\\[38;2;114;124;214m…')"
check "cache sits after context"  "yes" "$(pc true 1h 3480 | row1 | plain | grep -q '7% · Cache ██████████ 58m$' && echo yes || echo no)"
check "context bar purple at 75%"        "yes" "$(echo '{"model":{"display_name":"Opus 5.5"},"context_window":{"used_percentage":75,"context_window_size":1000000}}' | row1 | has "${G}████████"$'\e\\[0m')"
check "cache bar purple, words blue"   "yes" "$(pc true 1h 480 | row1 | has "${U}Cache"$'\e\\[0m'" *${G}██")"
# the two rows line up as a table: every row-2 dot sits under a row-1 dot, and the bars start together
align() { python3 -c '
import sys,re
rows=[re.sub(r"\x1b\[[0-9;]*m","",l.rstrip("\n")) for l in sys.stdin][:2]
bars=[[m.start() for m in re.finditer("[█░]{10}",r)] for r in rows]
k=min(len(b) for b in bars)
ends = len(rows[0]) == len(rows[1]) if len(bars[0]) == len(bars[1]) else True
tail=any(r.endswith(" ") for r in rows)
print("aligned" if bars[0][:k] == bars[1][:k] and ends and not tail else "not aligned: bars %s lengths %s tail=%s" % (bars, [len(r) for r in rows], tail))'; }
full() { payload 4 230 12 7000 | jq -c --argjson now "$now" '.prompt_cache = {warm: true, ttl: "1h", expires_at: ($now + 3480)}'; }
seed ok
check "rows line up: bars in the same columns" "aligned" "$(full | run | align)"
seedu fresh
check "rows line up with Fable too"      "aligned" "$(full | run | align)"
seedu none
check "rows line up with an amber meter" "aligned" "$(payload 4 230 83 950 | jq -c --argjson now "$now" '.prompt_cache = {warm: true, ttl: "1h", expires_at: ($now + 3480)}' | run | align)"
check "no limits: row 2 is the model, effort and cost" "Opus 5 (1M) · Max Effort · \$0.98" "$(payload - 0 - 0 | jq -c --argjson now "$now" '.prompt_cache = {warm: true, ttl: "1h", expires_at: ($now + 3480)}' | run | sed -n 2p | plain)"
check "no limits: row 1 still whole"      "✓ Claude operational · Context █░░░░░░░░░ 7% · Cache ██████████ 58m" "$(payload - 0 - 0 | jq -c --argjson now "$now" '.prompt_cache = {warm: true, ttl: "1h", expires_at: ($now + 3480)}' | run | sed -n 1p | plain | nophrase1)"
# the phrase, top left of row 1: sized to the room row 2 leaves, gradient and bold, only while all is clear.
# With the plan (Max 20x) and a $1234.56 cost after a model name of n letters (no effort), row 2's
# head is n + 21 wide; row 1 is the phrase + " · ✓ Claude operational" (23), so the room is n - 2.
# ph r gives the phrase for a room of r.
acct claude_max '"default_claude_max_20x"'; aged 2>/dev/null
ph() { jq -nc --arg n "$(printf "%$(($1 + 2))s" | tr ' ' x)" '{model: {display_name: $n}, cost: {total_cost_usd: 1234.56}}' | run | sed -n 1p | plain | sed -E 's/ · .*$//'; }
check "phrase: 9"                  "BANGARANG"                        "$(ph 9)"
check "phrase: 10, an exclamation" "BANGARANG!"                       "$(ph 10)"
check "phrase: 11"                 "BANGARANG!!"                      "$(ph 11)"
check "phrase: 13, a chevron"      "» BANGARANG «"                    "$(ph 13)"
check "phrase: 17, letter-spaced"  "B A N G A R A N G"                "$(ph 17)"
check "phrase: 19"                 "B A N G A R A N G!!"              "$(ph 19)"
check "phrase: 21"                 "» B A N G A R A N G «"            "$(ph 21)"
check "phrase: 23"                 "»» B A N G A R A N G ««"          "$(ph 23)"
check "phrase: 25, three chevrons" "»»» B A N G A R A N G «««"        "$(ph 25)"
check "phrase: 26"                 "»»» B A N G A R A N G! «««"       "$(ph 26)"
check "phrase: 27, four chevrons"  "»»»» B A N G A R A N G ««««"      "$(ph 27)"
check "phrase: 29, hearts outside" "♥ »»» B A N G A R A N G ««« ♥"    "$(ph 29)"
check "phrase: 31"                 "♥ »»»» B A N G A R A N G «««« ♥"  "$(ph 31)"
check "phrase: 33, two hearts"     "♥ ♥ »»» B A N G A R A N G ««« ♥ ♥" "$(ph 33)"
check "phrase: 34"                 "♥ ♥ »»» B A N G A R A N G! ««« ♥ ♥" "$(ph 34)"
check "phrase: never under 9, row 2 makes room" "BANGARANG BANGARANG" "$(ph 8) $(ph 3)"
check "phrase: fills its room at every width" "yes" "$(for r in $(seq 9 40); do ph $r | python3 -c "import sys; print('yes' if len(sys.stdin.read().rstrip('\\n')) == $r else 'no at $r')"; done | sort -u | tr '\n' ' ' | sed 's/ $//')"
# your own word: --phrase WORD, --phrase=WORD or BANGARANG_PHRASE=WORD
phw() { jq -nc --arg n "$(printf "%$(($2 + 2))s" | tr ' ' x)" '{model: {display_name: $n}, cost: {total_cost_usd: 1234.56}}' | HOME="$dh" PATH="$T/datebin:$PATH" FAKE_NOW="$now" bash "$new" --usage --phrase "$1" | unbox | sed -n 1p | plain | sed -E 's/ · .*$//'; }
check "phrase: your own word with --phrase"     "»» L F G ««" "$(phw LFG 11)"
check "phrase: --phrase=WORD works too"         "yes" "$(full | HOME="$dh" PATH="$T/datebin:$PATH" FAKE_NOW="$now" bash "$new" --usage --phrase=VIBES | unbox | sed -n 1p | plain | grep -q 'V I B E S' && echo yes || echo no)"
check "phrase: so does BANGARANG_PHRASE"        "yes" "$(full | HOME="$dh" PATH="$T/datebin:$PATH" FAKE_NOW="$now" BANGARANG_PHRASE=VIBES bash "$new" --usage | unbox | sed -n 1p | plain | grep -q 'V I B E S' && echo yes || echo no)"
check "phrase: your word fills its room at every width" "yes" "$(for r in $(seq 6 40); do phw WOOHOO $r | python3 -c "import sys; print('yes' if len(sys.stdin.read().rstrip('\\n')) == $r else 'no at $r')"; done | sort -u | tr '\n' ' ' | sed 's/ $//')"
check "phrase: your word never leaves either"   "WOOHOO" "$(phw WOOHOO 2)"
check "phrase: an empty --phrase keeps BANGARANG" "yes" "$(phw '' 17 | grep -q 'B A N G A R A N G' && echo yes || echo no)"
check "phrase: gradient starts clay, bold"  "yes" "$(jq -nc '{model: {display_name: "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}, cost: {total_cost_usd: 1234.56}}' | run | sed -n 1p | has $'^\e\\[1;38;2;215;135;95m♥')"
check "phrase: gradient ends blue, bold"    "yes" "$(jq -nc '{model: {display_name: "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}, cost: {total_cost_usd: 1234.56}}' | run | sed -n 1p | has $'\e\\[1;38;2;89;136;213m♥\e\\[0m\e\\[38;2;98;106;133m · ')"
check "phrase: the status follows it"  "yes" "$(full | run | sed -n 1p | plain | grep -qE '^(♥ )*(»+ )?(B A N G A R A N G|BANGARANG)!*( «+)?( ♥)* · ✓ Claude operational · Context ' && echo yes || echo no)"
rm -f "$dh/.claude.json" "$dc"/plan*
check "phrase: the plan and cost sit on row 2" "0 0" "$(full | run | sed -n 1p | plain | grep -c '\$0.98') $(acct claude_max '"default_claude_max_20x"'; full | run | sed -n 1p | plain | grep -c 'Max 20x')"
rm -f "$dh/.claude.json" "$dc"/plan*
seed "warn:Claude Code degraded"
check "phrase: stays during an outage" "1" "$(full | run | sed -n 1p | plain | grep -c 'BANG\|B A N')"
check "outage: BANGARANG, then the outage" "yes" "$(full | run | sed -n 1p | plain | grep -qE '^(♥ )*(»+ )?(B A N G A R A N G|BANGARANG)!*( «+)?( ♥)* · ✕ Claude Outage · Context ' && echo yes || echo no)"
check "outage: the rows stay lined up" "aligned" "$(full | run | align)"
seed ok
# the refill timer: the session window's time left
check "refill: 230m left, 2 cells filled, 4hr" "Refill ██░░░░░░░░ 4hr" "$(full | run | sed -n 1p | plain | grep -o 'Refill [█░]* [0-9]*[a-z]*')"
check "refill: 42m left, 8 cells filled, in minutes" "Refill ████████░░ 42m" "$(payload 4 42 12 7000 | run | sed -n 1p | plain | grep -o 'Refill [█░]* [0-9]*[a-z]*')"
check "refill: empty just after a reset"   "Refill ░░░░░░░░░░ 5hr" "$(payload 4 299 12 7000 | run | sed -n 1p | plain | grep -o 'Refill [█░]* [0-9]*[a-z]*')"
check "refill: 9 cells in the last half hour" "Refill █████████░ 12m" "$(payload 4 12 12 7000 | run | sed -n 1p | plain | grep -o 'Refill [█░]* [0-9]*[a-z]*')"
check "refill: none once the window reset" "0" "$(row1 < "$here/base.json" | plain | grep -c Refill)"
# both rows end on the same column when they have as many cells (numbers right-aligned in the last column)
seedu fresh
check "rows end together: 4h over 2%"     "same" "$(full | run | head -2 | sed $'s/\e\\[[0-9;]*m//g' | python3 -c 'import sys; print("same" if len({len(l.rstrip("\n")) for l in sys.stdin}) == 1 else "differ")')"
check "rows end together: 42m over 2%"    "same" "$(payload 4 42 12 7000 | jq -c --argjson now "$now" '.prompt_cache = {warm: true, ttl: "1h", expires_at: ($now + 3480)}' | run | sed $'s/\e\\[[0-9;]*m//g' | python3 -c 'import sys; print("same" if len({len(l.rstrip("\n")) for l in sys.stdin}) == 1 else "differ")')"
seedu none
# even spacing: with two-digit numbers throughout, neither row has a double space
jq -n --argjson at "$now" '{at: $at, scoped: [{name: "Fable", percent: 12}]}' > "$dc/usage.json"; touch "$dc/usage-checked"
check "even spacing: no double spaces"   "0 0" "$(full | run | sed $'s/\e\\[[0-9;]*m//g' | awk '{n=gsub(/  /,"&"); printf "%s ", n}' | sed 's/ $//')"
check "even spacing: rows still equal"   "same" "$(full | run | sed $'s/\e\\[[0-9;]*m//g' | python3 -c 'import sys; print("same" if len({len(l.rstrip("\n")) for l in sys.stdin}) == 1 else "differ")')"
seedu none
seed "warn:Claude Code degraded, Claude API partial outage, claude.ai major outage +1 more"
check "a many-service outage is still just Claude Outage, lined up" "yes aligned" "$(full | run | sed -n 1p | plain | grep -q '✕ Claude Outage · Context' && echo yes || echo no) $(full | run | align)"
seed ok
check "cost in the sage"                  "yes" "$(raw2 < "$here/base.json" | has $'\e\\[38;2;135;169;141m\\$0.98')"
check "fast gold"                      "yes" "$(echo '{"model":{"display_name":"Opus 5.5"},"fast_mode":true}' | raw2 | has $'\e\\[38;2;240;195;90mfast')"
check "no faint grey left anywhere"    "0"   "$(payload 4 230 83 950 | run | grep -c $'\e\\[2m')"
check "all clear is the calm sage, words too" "yes" "$(payload 4 230 12 7000 | row1 | has $'\e\\[38;2;135;169;141m✓ Claude operational')"
seed "crit:Claude API major outage"
check "critical is bold Pulseous red" "yes" "$(payload 4 230 12 7000 | row1 | has $'\e\\[1;38;2;232;92;92m✕ Claude Outage')"
seed "info:Claude API under maintenance"
check "maintenance is Pulseous blue, and says maintenance" "yes" "$(payload 4 230 12 7000 | row1 | has $'\e\\[38;2;77;155;232m✕ Claude Maintenance')"

# the box: a rainbow rule above and below with rounded corners, a side line a space off each end of every row
# (with the Fable meter both rows have four cells, so rows 1 and 2 end together)
seed ok; seedu fresh
widths() { sed $'s/\e\\[[0-9;]*m//g' | python3 -c 'import sys; print(" ".join(str(len(l.rstrip("\n"))) for l in sys.stdin))'; }
top() { runfull | sed -n 1p; }
codes() { grep -o $'\e\\[38;2;[0-9;]*m' | tr -d '\033'; }
check "box: four lines, rules above and below"   "4" "$(full | runfull | awk 'END {print NR}')"
check "box: rounded corners"                     "yes yes" "$(full | top | plain | grep -qE '^╭─+╮$' && echo yes || echo no) $(full | runfull | sed -n '$p' | plain | grep -qE '^╰─+╯$' && echo yes || echo no)"
check "box: a side line a space before Opus"     "yes" "$(full | runfull | sed -n 3p | plain | grep -q '^│ Opus 5 (1M) · ' && echo yes || echo no)"
nudge=$(( (now / 60) % 2 ))
check "box: side lines in the corner colours"    "yes" "$(full | runfull | sed -n 2p | grep -q $'^\e\\[38;2;244;146;'"$((138 + nudge))"$'m│\e\\[0m .*\e\\[38;2;211;152;'"$((224 + nudge))"$'m│\e\\[0m$' && echo yes || echo no)"
check "box: square, one space inside at the widest row, at either width" "yes yes" "$(for e in max high; do full | jq -c --arg e $e '.effort.level = $e' | runfull | sed $'s/\e\\[[0-9;]*m//g' | python3 -c '
import sys, re
rows = [l.rstrip("\n") for l in sys.stdin]
w = len(rows[0])
inner = rows[1:-1]
ok = (all(len(r) == w for r in rows) and all(r.startswith("│ ") and r.endswith(" │") for r in inner)
      and any(not r[:-2].endswith(" ") for r in inner))
print("yes" if ok else "no: %r" % [len(r) for r in rows])'; done | tr '\n' ' ' | sed 's/ $//')"
check "box: the top rule starts red and ends violet" "[38;2;244;146;$((138 + nudge))m [38;2;211;152;$((224 + nudge))m" "$(full | top | codes | sed -n '1p;$p' | tr '\n' ' ' | sed 's/ $//')"
nextmin() { HOME="$dh" PATH="$T/datebin:$PATH" FAKE_NOW="$((now + 60))" bash "$new" --usage; }
check "box: the colours step each minute, so Claude Code repaints the box" "differ" "$([ "$(full | top | codes)" != "$(full | nextmin | sed -n 1p | codes)" ] && echo differ || echo same)"
check "box: by one unit of blue, nothing you can see" "1" "$(a=$(full | top | codes | head -1 | tr -d '[m' | cut -d';' -f5); b=$(full | nextmin | sed -n 1p | codes | head -1 | tr -d '[m' | cut -d';' -f5); d=$((a - b)); echo ${d#-})"
check "box: a rainbow along the top"             "yes" "$(full | top | codes | sort -u | awk 'END {print (NR > 40) ? "yes" : "no: " NR}')"
check "box: the bottom rule in the same colours" "same" "$(o=$(full | runfull); [ "$(echo "$o" | sed -n 1p | codes)" = "$(echo "$o" | sed -n '$p' | codes)" ] && echo same || echo differ)"
check "box: one colour reset, at the end of a rule" "1" "$(full | top | grep -o $'\e\\[0m' | wc -l | tr -d ' ')"
seed "warn:Claude Code degraded, Claude API partial outage, claude.ai major outage +1 more"
check "box: still square when the rows are unaligned" "yes unaligned" "$(echo '{"model":{"id":"x"}}' | runfull | widths | awk '{print ($1 == $2 && $2 == $3 && $3 == $4) ? "yes" : "no: " $0}') $(echo '{"model":{"id":"x"}}' | run | widths | awk '{print ($1 != $2) ? "unaligned" : "aligned?"}')"
check "box: BANGARANG shows when unaligned too" "» B A N G A R A N G «" "$(echo '{"model":{"id":"x"}}' | run | sed -n 1p | plain | sed -E 's/ · .*$//')"
seed ok
check "box: two rows in, four lines out, whatever the payload" "4" "$(echo '{}' | runfull | awk 'END {print NR}')"
seedu none

# row 1 for a handful of payloads, from full to bare
seed ok
check "row 2 head: full"          "Opus 5 (1M) · Max Effort · \$0.98" "$(head2 < "$here/base.json")"
check "row 1: the status and Context after the phrase" "✓ Claude operational · Context █░░░░░░░░░ 7% · Cache ░░░░░░░░░░ …" "$(row1 < "$here/base.json" | plain | nophrase1)"
check "row 2 head: effort only"   "Opus 5.5 · Max Effort" "$(echo '{"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"effort":{"level":"max"}}' | head2)"
check "row 2 head: fast, 200k, cost" "Sonnet 5 (200k) · fast · \$12.50" "$(echo '{"model":{"id":"claude-sonnet-5","display_name":"Sonnet 5"},"fast_mode":true,"context_window":{"used_percentage":93,"context_window_size":200000},"cost":{"total_cost_usd":12.5}}' | head2)"
check "row 1: the status and a full Context" "✓ Claude operational · Context ██████████ 93% · Cache ░░░░░░░░░░ …" "$(echo '{"model":{"id":"claude-sonnet-5","display_name":"Sonnet 5"},"fast_mode":true,"context_window":{"used_percentage":93,"context_window_size":200000},"cost":{"total_cost_usd":12.5}}' | row1 | plain | nophrase1)"
check "row 2 head: id only"       "x" "$(echo '{"model":{"id":"x"}}' | head2)"
check "row 2 head: nothing at all" "unknown model" "$(echo '{}' | head2)"

# the plan, from the tier Claude Code keeps in ~/.claude.json (only re-read when that file changes)
rm -f "$dc"/plan*; acct claude_max '"default_claude_max_20x"'
check "Max 20x after the effort"     "Opus 5 (1M) · Max Effort · Max 20x · \$0.98" "$(head2 < "$here/base.json")"
check "plan in red"                  "yes" "$(raw2 < "$here/base.json" | has $'\e\\[38;2;232;142;144mMax 20x')"
check "the plan is not on row 1"     "0" "$(row1 < "$here/base.json" | plain | grep -c 'Max 20x')"
aged; acct claude_max '"default_claude_max_5x"'
check "a plan change is picked up"   "Opus 5 (1M) · Max Effort · Max 5x · \$0.98" "$(head2 < "$here/base.json")"
aged; acct claude_pro null
check "Pro plan"                     "Opus 5 (1M) · Max Effort · Pro · \$0.98" "$(head2 < "$here/base.json")"
aged; acct claude_max '"default_claude_max_20x"'; row1 < "$here/base.json" >/dev/null
aged; printf '{"oauthAccount":{"organizationType":"claude_' > "$dh/.claude.json"
check "half-written file keeps the last plan" "Opus 5 (1M) · Max Effort · Max 20x · \$0.98" "$(head2 < "$here/base.json")"
check "and leaves no temp file"      "none" "$(ls "$dc" | grep -q 'plan\.' && echo leftover || echo none)"
rm -f "$dh/.claude.json" "$dc"/plan*
check "no account file: no plan"     "Opus 5 (1M) · Max Effort · \$0.98" "$(head2 < "$here/base.json")"
check "the email is never read out"  "0" "$(cat "$dc"/plan 2>/dev/null | grep -c example)"

# stays quick: 20 runs
start=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
for i in $(seq 20); do payload 4 230 83 950 | HOME="$dh" bash "$new" >/dev/null; done
end=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
echo "20 runs (payload build included): $(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.3f", b - a }')s"

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
