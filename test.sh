#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

export SCRATCH="$(mktemp -d)"
export WARMLINE_NO_COLOR=1
# the host machine may configure these; the tests assume the defaults
unset WARMLINE_TTL_MIN WARMLINE_REFRESH_SEC WARMLINE_FORCE_COLOR
# an empty config dir, so the keep-warm field of the statusline tests below
# reads a known-OFF state instead of whoever's real ~/.claude/CLAUDE.md
export CLAUDE_CONFIG_DIR="$SCRATCH/cfg"
mkdir -p "$CLAUDE_CONFIG_DIR"
trap 'rm -rf "$SCRATCH"' EXIT

# A synthetic Claude Code cost record, so derived prices are deterministic and
# the developer's real ~/.claude.json is never read. Each entry solves to a
# round rate: input-equivalent = in + 5*out + 2*write + 0.1*read, and
# lastCost / that = the $/MTok the assertions below expect.
python3 - "$CLAUDE_CONFIG_DIR/.claude.json" "$PWD" <<'PY'
import json, sys
def entry(rate, sid="s"):
    tok = dict(lastTotalInputTokens=100000, lastTotalOutputTokens=20000,
               lastTotalCacheCreationInputTokens=500000,
               lastTotalCacheReadInputTokens=4000000,
               lastTotalWebSearchRequests=0, lastSessionId=sid)
    tok["lastCost"] = rate * 1.6   # 1.6 MTok input-equivalent
    return tok
json.dump({"projects": {sys.argv[2]: entry(3.0),          # the repo: $3/MTok
                        "/tmp/priced-a": entry(10.0),
                        "/tmp/priced-b": entry(5.0)}},
          open(sys.argv[1], "w"))
PY

pass=0 fail=0
check() { # name expected payload
  local out
  out=$(printf '%s' "$3" | ./statusline.py)
  if [[ "$out" == *"$2"* ]]; then
    echo "ok   $1: $out"; pass=$((pass + 1))
  else
    echo "FAIL $1: expected '$2' in: $out"; fail=$((fail + 1))
  fi
}

# --- statusline: the cache verdict comes only from `prompt_cache` ----------
# Every payload below is built by hand rather than replayed from a transcript,
# because that is now the whole contract: no stamp file, no transcript read,
# no gap timing. What Claude Code says is what the line shows.

mkpayload() { # session_id  prompt_cache_json (empty = absent)  [pct] [tokens]
              # [window: 0 omits the field]  [rate_limits json]
  python3 - "$1" "$2" "${3:-42.7}" "${4:-85400}" "${5:-200000}" "${6:-}" <<'PY'
import json, sys
d = {
    "session_id": sys.argv[1],
    "model": {"display_name": "Test"},
    "workspace": {"current_dir": "/tmp/proj"},
    "context_window": {
        # pct and tokens agree, as Claude Code's own payload does: it rounds
        # the one from the other against the window below
        "used_percentage": float(sys.argv[3]),
        "total_input_tokens": int(sys.argv[4]),
        # deliberately non-zero: the old statusline read these to guess the
        # verdict, and the false-HOT regression below depends on them staying
        # present while `warm` says otherwise
        "current_usage": {"cache_read_input_tokens": 165000,
                          "cache_creation_input_tokens": 2000},
    },
}
if sys.argv[5] != "0":
    d["context_window"]["context_window_size"] = int(sys.argv[5])
if sys.argv[2]:
    d["prompt_cache"] = json.loads(sys.argv[2])
if sys.argv[6]:
    d["rate_limits"] = json.loads(sys.argv[6])
print(json.dumps(d))
PY
}

pc() { # minutes_until_expiry ttl  -> a warm prompt_cache object
  python3 -c 'import json,sys,time
print(json.dumps({"warm": True, "caching_observed": True, "ttl": sys.argv[2],
                  "expires_at": time.time() + float(sys.argv[1]) * 60}))' "$1" "$2"
}
at() { # minutes_from_now -> HH:MM, the label the line should carry
  python3 -c 'import sys,time
print(time.strftime("%H:%M", time.localtime(time.time() + float(sys.argv[1]) * 60)))' "$1"
}

HOT=$(mkpayload t1 "$(pc 40 1h)")

check hot-expiry "cache HOT (cold ~$(at 40))" "$HOT"
check warm-noexp "cache HOT" \
  "$(mkpayload t2 '{"warm":true,"caching_observed":true,"ttl":"1h","expires_at":null}')"
check cold       "cache COLD" \
  "$(mkpayload t3 '{"warm":false,"caching_observed":true,"ttl":"1h","expires_at":null}')"
check off        "cache off" \
  "$(mkpayload t4 '{"warm":false,"caching_observed":false,"ttl":"1h","expires_at":null}')"
check absent     "cache ?"   "$(mkpayload t5 '')"
check unusable   "cache ?"   "$(mkpayload t6 '{"caching_observed":true}')"
check garbage    "bad input" 'not json'

# THE REGRESSION. Until this release the verdict was inferred from
# cache_read_input_tokens, so a payload whose authoritative `warm` is false
# while the (one-turn-stale) usage fields still show a large read rendered a
# confident green "cache HOT" -- the exact failure this release exists to fix.
out=$(printf '%s' \
  "$(mkpayload r1 '{"warm":false,"caching_observed":true,"ttl":"1h","expires_at":null}')" \
  | ./statusline.py)
if [[ "$out" == *"cache COLD"* && "$out" != *"HOT"* ]]; then
  echo "ok   false-hot: warm=false renders COLD despite a 165k cache read"; pass=$((pass + 1))
else
  echo "FAIL false-hot: authoritative warm=false rendered as: $out"; fail=$((fail + 1))
fi

# The shape a real expiry actually has, captured off 2.1.252: `warm` flips to
# false but `expires_at` keeps its old value instead of going null, so a
# renderer that trusted the clock over `warm` would still be inside the TTL
# for a moment and paint HOT. Warmth comes from `warm`, the clock only labels.
out=$(printf '%s' \
  "$(mkpayload r1b "{\"warm\":false,\"caching_observed\":true,\"ttl\":\"5m\",\"expires_at\":$(python3 -c 'import time;print(int(time.time())+120)')}")" \
  | ./statusline.py)
if [[ "$out" == *"cache COLD"* && "$out" != *"HOT"* ]]; then
  echo "ok   expired-stale-clock: warm=false beats a still-future expires_at"; pass=$((pass + 1))
else
  echo "FAIL expired-stale-clock: rendered as: $out"; fail=$((fail + 1))
fi

# caching_observed=false wins over warm: "nothing to wait for" is a different
# fact from "expired", and must not be shown as a cache that might come back.
out=$(printf '%s' \
  "$(mkpayload r2 '{"warm":true,"caching_observed":false,"ttl":"1h","expires_at":null}')" \
  | ./statusline.py)
if [[ "$out" == *"cache off"* ]]; then
  echo "ok   off-precedence: caching_observed=false outranks warm"; pass=$((pass + 1))
else
  echo "FAIL off-precedence: $out"; fail=$((fail + 1))
fi

# An expiry already in the past reads COLD even though `warm` still says true:
# the authoritative timestamp is the newer fact. This is what keeps a line
# frozen on screen honest if the expires_at re-run never arrives.
out=$(printf '%s' "$(mkpayload r3 "$(pc -5 1h)")" | ./statusline.py)
if [[ "$out" == *"cache COLD"* ]]; then
  echo "ok   past-expiry: a lapsed expires_at reads COLD, not HOT"; pass=$((pass + 1))
else
  echo "FAIL past-expiry: $out"; fail=$((fail + 1))
fi

# Approaching expiry is a colour change and nothing else: byte-identical text,
# so no field shifts width as the deadline nears.
warn=$(printf '%s' "$(mkpayload r4 "$(pc 9 1h)")" | env -u WARMLINE_NO_COLOR ./statusline.py)
calm=$(printf '%s' "$(mkpayload r5 "$(pc 40 1h)")" | env -u WARMLINE_NO_COLOR ./statusline.py)
if [[ "$warn" == *$'\033[33mcache HOT (cold ~'*$'\033[0m'* \
   && "$calm" == *$'\033[32mcache HOT (cold ~'*$'\033[0m'* ]]; then
  echo "ok   warn-colour: yellow inside 15m, green outside, same wording"; pass=$((pass + 1))
else
  echo "FAIL warn-colour: ${warn@Q} / ${calm@Q}"; fail=$((fail + 1))
fi

# The 5m bucket is badged because it invalidates the mental model built on the
# 1h default; the 1h case stays unlabelled. Its warning window scales with the
# TTL, so a 4-minute-old 5m cache is not permanently yellow.
five=$(printf '%s' "$(mkpayload r6 "$(pc 4 5m)")" | env -u WARMLINE_NO_COLOR ./statusline.py)
fivewarn=$(printf '%s' "$(mkpayload r7 "$(pc 2 5m)")" | env -u WARMLINE_NO_COLOR ./statusline.py)
if [[ "$five" == *$'\033[32mcache HOT 5m (cold ~'* \
   && "$fivewarn" == *$'\033[33mcache HOT 5m (cold ~'* \
   && "$calm" != *"1h"* ]]; then
  echo "ok   ttl-badge: 5m badged and scaled; 1h unlabelled"; pass=$((pass + 1))
else
  echo "FAIL ttl-badge: ${five@Q} / ${fivewarn@Q}"; fail=$((fail + 1))
fi

# Pin the warning window itself, on both sides of each boundary: 15 minutes of
# an hour, 2.5 of five, and an unrecognised ttl left uncapped at 15. The 5m cap
# is what stops a flat 15 minutes from painting a 5-minute cache yellow for its
# whole life; the shape of that rule should not drift unnoticed.
colour() { # minutes_left  ttl -> GREEN | YELLOW
  local o
  o=$(printf '%s' "$(mkpayload rb "$(pc "$1" "$2")")" | env -u WARMLINE_NO_COLOR ./statusline.py)
  case "$o" in
    *$'\033[33mcache HOT'*) echo YELLOW ;;
    *$'\033[32mcache HOT'*) echo GREEN ;;
    *) echo "other:$o" ;;
  esac
}
edges="$(colour 15.5 1h)/$(colour 14.5 1h) $(colour 2.6 5m)/$(colour 2.4 5m) $(colour 15.5 7d)/$(colour 14.5 7d)"
if [[ "$edges" == "GREEN/YELLOW GREEN/YELLOW GREEN/YELLOW" ]]; then
  echo "ok   warn-window: yellow under 15m (1h), 2.5m (5m), 15m (unknown ttl)"; pass=$((pass + 1))
else
  echo "FAIL warn-window: $edges"; fail=$((fail + 1))
fi

# Deleted machinery must stay deleted: no gap field, no state directory, and
# no transcript read. A transcript_path pointing at a 5m-bucket write used to
# change the verdict; now it is ignored entirely.
SNIFF="$SCRATCH/sniff-transcript.jsonl"
printf '%s\n' '{"type":"assistant","message":{"usage":{"cache_creation":{"ephemeral_5m_input_tokens":9000,"ephemeral_1h_input_tokens":0}}}}' > "$SNIFF"
withtx=$(python3 -c 'import json,sys
d = json.loads(sys.argv[1]); d["transcript_path"] = sys.argv[2]; print(json.dumps(d))' \
  "$(mkpayload r8 "$(pc 40 1h)")" "$SNIFF")
before=$(ls -A "$SCRATCH" | wc -l)
out=$(printf '%s' "$withtx" | ./statusline.py)
after=$(ls -A "$SCRATCH" | wc -l)
if [[ "$out" == *"cache HOT (cold ~$(at 40))"* && "$out" != *"5m"* \
   && "$out" != *"gap "* && "$before" == "$after" ]]; then
  echo "ok   no-inference: transcript ignored, no gap field, no files written"; pass=$((pass + 1))
else
  echo "FAIL no-inference: $out (files $before -> $after)"; fail=$((fail + 1))
fi

# ...and enforced at the source level, so a future edit can't quietly
# reintroduce statusline-side state or a transcript read.
if ! grep -qE 'makedirs|os\.utime|getmtime|transcript_path|,[[:space:]]*["'"'"']w["'"'"']' statusline.py; then
  echo "ok   no-state-source: statusline.py writes nothing and reads no transcript"; pass=$((pass + 1))
else
  echo "FAIL no-state-source: statusline.py still contains state/inference code"; fail=$((fail + 1))
fi

# Colors on by default.
out=$(printf '%s' "$(mkpayload r9 "$(pc 40 1h)")" | env -u WARMLINE_NO_COLOR ./statusline.py)
if [[ "$out" == *$'\033[32mcache HOT'* ]]; then
  echo "ok   color: green HOT emitted"; pass=$((pass + 1))
else
  echo "FAIL color: no green ANSI code in: ${out@Q}"; fail=$((fail + 1))
fi
out=$(printf '%s' "$(mkpayload ra '{"warm":false,"caching_observed":true}')" \
  | env -u WARMLINE_NO_COLOR ./statusline.py)
if [[ "$out" == *$'\033[31mcache COLD\033[0m'* ]]; then
  echo "ok   color-cold: red COLD emitted"; pass=$((pass + 1))
else
  echo "FAIL color-cold: ${out@Q}"; fail=$((fail + 1))
fi

# Keep-warm is now an exception-only field: a correct policy and a deliberate
# absence are both silent, and only the two states you must act on appear.
KWMD="$CLAUDE_CONFIG_DIR/CLAUDE.md"
KWPOL="$CLAUDE_CONFIG_DIR/warmline-keep-warm.md"
BLOCK_B='<!-- >>> claude-warmline keep-warm >>> -->'
BLOCK_E='<!-- <<< claude-warmline keep-warm <<< -->'

out=$(printf '%s' "$(mkpayload k1 "$(pc 40 1h)")" | ./statusline.py)   # no CLAUDE.md
if [[ "$out" != *"keep-warm"* ]]; then
  echo "ok   kw-silent-off: no policy, no field"; pass=$((pass + 1))
else
  echo "FAIL kw-silent-off: $out"; fail=$((fail + 1))
fi

printf '%s\npolicy body\n%s\n' "$BLOCK_B" "$BLOCK_E" > "$KWMD"
printf 'policy   body\n' > "$KWPOL"      # whitespace-insensitive, like the CLI
out=$(printf '%s' "$(mkpayload k2 "$(pc 40 1h)")" | ./statusline.py)
if [[ "$out" != *"keep-warm"* ]]; then
  echo "ok   kw-silent-on: a current policy renders nothing"; pass=$((pass + 1))
else
  echo "FAIL kw-silent-on: expected silence, got: $out"; fail=$((fail + 1))
fi

printf 'policy body, revised in a later release\n' > "$KWPOL"
check kw-stale "keep-warm on*" "$(mkpayload k3 "$(pc 40 1h)")"
out=$(printf '%s' "$(mkpayload k4 "$(pc 40 1h)")" | env -u WARMLINE_NO_COLOR ./statusline.py)
if [[ "$out" == *$'\033[33mkeep-warm on*\033[0m'* ]]; then
  echo "ok   kw-stale-color: yellow keep-warm on* emitted"; pass=$((pass + 1))
else
  echo "FAIL kw-stale-color: ${out@Q}"; fail=$((fail + 1))
fi

rm -f "$KWPOL"
out=$(printf '%s' "$(mkpayload k5 "$(pc 40 1h)")" | ./statusline.py)
if [[ "$out" != *"keep-warm"* ]]; then
  echo "ok   kw-nopolicy: nothing to compare against, so no false stale"; pass=$((pass + 1))
else
  echo "FAIL kw-nopolicy: $out"; fail=$((fail + 1))
fi

printf 'user text\n%s\npolicy body\n' "$BLOCK_B" > "$KWMD"   # end marker lost
check kw-malformed "keep-warm ?" "$(mkpayload k6 "$(pc 40 1h)")"
out=$(printf '%s' "$(mkpayload k7 "$(pc 40 1h)")" | WARMLINE_NO_KEEPWARM=1 ./statusline.py)
if [[ "$out" != *"keep-warm"* && "$out" == *"cache HOT"* ]]; then
  echo "ok   kw-optout: field suppressed even when malformed"; pass=$((pass + 1))
else
  echo "FAIL kw-optout: $out"; fail=$((fail + 1))
fi
rm -f "$KWMD"

# Auto-compact proximity: the compaction nobody chooses fires near the top of
# the window and rewrites the prefix, so ctx goes yellow before it -- at the
# threshold Claude Code actually uses (window - 33000), not a round guess.
sl() { printf '%s' "$1" | env -u WARMLINE_NO_COLOR "${@:2}" ./statusline.py; }
CTXHI=$(mkpayload c1 "$(pc 40 1h)" 86.0 172000)          # 5k inside 167000
out=$(sl "$CTXHI")
out2=$(sl "$(mkpayload c2 "$(pc 40 1h)" 86.0 172000)" env WARMLINE_CTX_WARN_PCT=0)
out3=$(sl "$HOT")                                        # 43%, nowhere near
out4=$(sl "$(mkpayload c4 "$(pc 40 1h)" 86.0 172000)" env WARMLINE_CTX_WARN_PCT=nonsense)
if [[ "$out" == *$'\033[33mctx 86% (172k)\033[0m'* && "$out2" == *"ctx 86% (172k) |"* \
   && "$out2" != *$'\033[33mctx'* && "$out3" != *$'\033[33mctx'* \
   && "$out4" == *$'\033[33mctx 86%'* ]]; then
  echo "ok   ctx-warn: yellow near the real threshold, 0 disables, junk = auto"; pass=$((pass + 1))
else
  echo "FAIL ctx-warn: ${out@Q} / ${out2@Q} / ${out3@Q} / ${out4@Q}"; fail=$((fail + 1))
fi

# The same 86% is nowhere near compaction in a 1M window (967k), so a
# percentage rule cries wolf there and the real threshold doesn't. An
# explicit WARMLINE_CTX_WARN_PCT still overrides both ways.
out=$(sl "$(mkpayload c5 "$(pc 40 1h)" 86.0 860000 1000000)")
out2=$(sl "$(mkpayload c6 "$(pc 40 1h)" 86.0 860000 1000000)" env WARMLINE_CTX_WARN_PCT=80)
if [[ "$out" != *$'\033[33mctx'* && "$out" == *"ctx 86% (860k)"* \
   && "$out2" == *$'\033[33mctx 86%'* ]]; then
  echo "ok   ctx-window: 86% of 1M stays plain, an explicit percent still warns"; pass=$((pass + 1))
else
  echo "FAIL ctx-window: ${out@Q} / ${out2@Q}"; fail=$((fail + 1))
fi

# Nothing to warn about when auto-compact can't fire, and nothing to compute
# from when the payload carries no window: silence beats a guess in both.
out=$(sl "$CTXHI" env DISABLE_AUTO_COMPACT=1)
printf '{"autoCompactEnabled": false}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
out2=$(sl "$CTXHI")
rm -f "$CLAUDE_CONFIG_DIR/settings.json"
out3=$(sl "$(mkpayload c7 "$(pc 40 1h)" 86.0 172000 0)")
if [[ "$out" != *$'\033[33mctx'* && "$out2" != *$'\033[33mctx'* \
   && "$out3" != *$'\033[33mctx'* && "$out3" == *"ctx 86%"* ]]; then
  echo "ok   ctx-nocompact: env, settings and an unknown window all stay quiet"; pass=$((pass + 1))
else
  echo "FAIL ctx-nocompact: ${out@Q} / ${out2@Q} / ${out3@Q}"; fail=$((fail + 1))
fi

# The stake: how big the next rebuild would be is the one number that says
# whether keeping this cache warm is worth a wakeup, so it rides inside the
# cache field rather than costing a segment of its own.
out=$(sl "$(mkpayload s1 '{"warm":true,"caching_observed":true,"ttl":"1h","expires_at":null,"recache_tokens_if_cold":127000}')")
out2=$(sl "$(mkpayload s2 '{"warm":true,"caching_observed":true,"ttl":"5m","expires_at":null,"recache_tokens_if_cold":1234567}')")
out3=$(sl "$(mkpayload s3 '{"warm":true,"caching_observed":true,"ttl":"1h","expires_at":null,"recache_tokens_if_cold":400}')")
out4=$(sl "$(mkpayload s4 "$(pc 40 1h)")")
if [[ "$out" == *"cache HOT (127k)"* && "$out2" == *"cache HOT 5m (1.2M)"* \
   && "$out3" == *"cache HOT"* && "$out3" != *"(0k"* && "$out3" != *"(400"* \
   && "$out4" == *"cache HOT (cold ~$(at 40))"* ]]; then
  echo "ok   cache-stake: rebuild size shown, rounded, hidden when trivial"; pass=$((pass + 1))
else
  echo "FAIL cache-stake: ${out@Q} / ${out2@Q} / ${out3@Q} / ${out4@Q}"; fail=$((fail + 1))
fi

# Plan limits are the currency a subscription user actually feels, and
# Claude Code hands them to the statusline: show the window nearest its cap,
# quietly until it matters, with the reset time once it does.
q() { python3 -c 'import json,sys,time
w = {"used_percentage": float(sys.argv[1])}
if len(sys.argv) > 2: w["resets_at"] = time.time() + float(sys.argv[2]) * 60
print(json.dumps({sys.argv[3] if len(sys.argv) > 3 else "five_hour": w}))' "$@"; }
out=$(sl "$(mkpayload q1 "$(pc 40 1h)" 42.7 85400 200000 "$(q 40)")")
out2=$(sl "$(mkpayload q2 "$(pc 40 1h)" 42.7 85400 200000 "$(q 62)")")
out3=$(sl "$(mkpayload q3 "$(pc 40 1h)" 42.7 85400 200000 "$(q 91 25)")")
out4=$(sl "$(mkpayload q4 "$(pc 40 1h)" 42.7 85400 200000 "$(q 96 25 seven_day)")")
out5=$(sl "$(mkpayload q5 "$(pc 40 1h)" 42.7 85400 200000 "$(q 91 25)")" env WARMLINE_NO_QUOTA=1)
if [[ "$out" != *"5h"* && "$out2" == *"| 5h 62%"* && "$out2" != *$'\033[33m5h'* \
   && "$out3" == *$'\033[33m5h 91% ('"$(at 25)"$')\033[0m'* \
   && "$out4" == *$'\033[31m7d 96% ('"$(at 25)"$')\033[0m'* \
   && "$out5" != *"5h"* ]]; then
  echo "ok   quota: hidden under 50%, plain, yellow with reset, red, opt-out"; pass=$((pass + 1))
else
  echo "FAIL quota: ${out@Q} / ${out2@Q} / ${out3@Q} / ${out4@Q} / ${out5@Q}"; fail=$((fail + 1))
fi

# API-key, Bedrock and Vertex sessions have no plan windows, so Claude Code
# sends no rate_limits at all: no field, no zeros, no invented 0%.
out=$(sl "$HOT")
if [[ "$out" != *"5h"* && "$out" != *"7d"* && "$out" == *"cache HOT"* ]]; then
  echo "ok   quota-absent: no plan limits in the payload, no quota field"; pass=$((pass + 1))
else
  echo "FAIL quota-absent: ${out@Q}"; fail=$((fail + 1))
fi

# warmline-audit: synthetic transcript with one of each verdict, a duplicate
# requestId (one API request, two entries) and a sidechain turn to exclude.
AUDIT_T="$SCRATCH/audit-test.jsonl"
cat > "$AUDIT_T" <<'EOF'
{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","requestId":"r1","message":{"usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":30000,"input_tokens":5}}}
{"type":"assistant","timestamp":"2026-01-01T00:02:00Z","requestId":"r2","message":{"usage":{"cache_read_input_tokens":30000,"cache_creation_input_tokens":500,"input_tokens":5}}}
{"type":"assistant","timestamp":"2026-01-01T00:02:30Z","requestId":"r2","message":{"usage":{"cache_read_input_tokens":30000,"cache_creation_input_tokens":500,"input_tokens":5}}}
{"type":"assistant","timestamp":"2026-01-01T00:03:00Z","requestId":"r3","isSidechain":true,"message":{"usage":{"cache_read_input_tokens":9,"cache_creation_input_tokens":9,"input_tokens":9}}}
{"type":"assistant","timestamp":"2026-01-01T01:22:00Z","requestId":"r4","message":{"usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":31000,"input_tokens":5}}}
{"type":"assistant","timestamp":"2026-01-01T01:24:00Z","requestId":"r5","message":{"usage":{"cache_read_input_tokens":10000,"cache_creation_input_tokens":20000,"input_tokens":5}}}
EOF
out=$(./warmline-audit "$AUDIT_T")
if [[ "$out" == *"4 API turns"* && "$out" == *"HOT 1"* && "$out" == *"PARTIAL 1"* \
   && "$out" == *"COLD(rebuilt) 1"* && "$out" == *"COLD(ttl) 1"* ]]; then
  echo "ok   audit: ${out##*$'\n'}"; pass=$((pass + 1))
else
  echo "FAIL audit: unexpected output:"; echo "$out"; fail=$((fail + 1))
fi

# Verdict census carries percentages of turns, so the relative share of
# cold events is readable without division: 1 of 4 turns each -> (25%).
if [[ "$out" == *"HOT 1 (25%)"* && "$out" == *"COLD(ttl) 1 (25%)"* ]]; then
  echo "ok   audit-pct: verdict census shows shares of turns"; pass=$((pass + 1))
else
  echo "FAIL audit-pct:"; echo "$out"; fail=$((fail + 1))
fi

# --price: 61,000 cold tokens at $10/MTok base input -> 61000*1.9*10/1e6;
# the avoidable premium counts only the non-session-start cold write (31,000).
# Output tokens bill at their own rate, defaulting to 5x input ($50 here).
out=$(./warmline-audit --price 10 "$AUDIT_T")
if [[ "$out" == *'cost ~$1.16 more'* \
   && "$out" == *'estimated avoidable premium ~$0.59'* \
   && "$out" == *'output tokens at $50/MTok'* \
   && "$out" == *'input $10/MTok as given on the command line'* ]]; then
  echo "ok   audit-price: cold cost \$1.16, premium \$0.59, output at 5x input"; pass=$((pass + 1))
else
  echo "FAIL audit-price: expected '~\$1.16', '~\$0.59', '\$50/MTok' in:"; echo "$out"; fail=$((fail + 1))
fi

# Bare --price derives the rate from Claude Code's own cost record (the
# fixture ledger solves to exactly $3/MTok, 5x = $15 output) and says so;
# --price-in / --price-out still override, and say that instead.
out=$(./warmline-audit --price "$AUDIT_T")
out2=$(./warmline-audit --price-in 10 --price-out 25 "$AUDIT_T")
if [[ "$out" == *'input $3/MTok, derived from'* \
   && "$out" == *'($4.80 over 1.6 MTok input-equivalent)'* \
   && "$out" == *'output tokens at $15/MTok'* \
   && "$out" == *'estimated avoidable premium ~$0.18'* \
   && "$out2" == *'input $10/MTok as given on the command line'* \
   && "$out2" == *'output tokens at $25/MTok'* ]]; then
  echo "ok   audit-price-defaults: bare --price derives \$3/\$15, flags override"; pass=$((pass + 1))
else
  echo "FAIL audit-price-defaults:"; echo "$out"; echo "$out2"; fail=$((fail + 1))
fi

# No cost record to solve from: the $3 placeholder is still used, but it is
# labeled ASSUMED rather than passed off as the user's rate.
out=$(HOME="$SCRATCH/nohome" CLAUDE_CONFIG_DIR="$SCRATCH/nohome" \
      ./warmline-audit --price "$AUDIT_T")
if [[ "$out" == *'input $3/MTok ASSUMED (Sonnet tier)'* \
   && "$out" == *"placeholder, not your price"* \
   && "$out" != *"derived from"* ]]; then
  echo "ok   audit-price-assumed: unreadable cost record labels its fallback"; pass=$((pass + 1))
else
  echo "FAIL audit-price-assumed:"; echo "$out"; fail=$((fail + 1))
fi

# The premium multiplier follows the session's own cache bucket: a 5m write
# costs 1.25x and a warm read 0.1x, so only 1.15x is avoidable -- not the
# 1.9x of the 1-hour bucket. Same tokens, 39% less premium.
A5M="$SCRATCH/audit-5m.jsonl"
python3 - "$AUDIT_T" "$A5M" <<'PY'
import json, sys
out = open(sys.argv[2], "w")
for line in open(sys.argv[1]):
    e = json.loads(line)
    u = e["message"]["usage"]
    u["cache_creation"] = {"ephemeral_5m_input_tokens": u["cache_creation_input_tokens"],
                           "ephemeral_1h_input_tokens": 0}
    out.write(json.dumps(e) + "\n")
PY
out=$(./warmline-audit --price 10 "$A5M")
if [[ "$out" == *"~1.25x base input on this session's 5m cache"* \
   && "$out" == *'estimated avoidable premium ~$0.36'* ]]; then
  echo "ok   premium-bucket: 5m session priced at 1.15x, not 1.9x"; pass=$((pass + 1))
else
  echo "FAIL premium-bucket:"; echo "$out"; fail=$((fail + 1))
fi

# Output tokens are summed from the transcript and priced at the output
# rate: 1,000 + 500 output tokens at the default $15/MTok -> ~$0.02.
AOUT="$SCRATCH/audit-out.jsonl"
cat > "$AOUT" <<'EOF'
{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","requestId":"o1","message":{"usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":30000,"input_tokens":5,"output_tokens":1000}}}
{"type":"assistant","timestamp":"2026-01-01T00:02:00Z","requestId":"o2","message":{"usage":{"cache_read_input_tokens":30000,"cache_creation_input_tokens":500,"input_tokens":5,"output_tokens":500}}}
EOF
out=$(./warmline-audit --price "$AOUT")
if [[ "$out" == *"output: 1,500"* && "$out" == *'output tokens at $15/MTok: ~$0.02'* ]]; then
  echo "ok   audit-output-tokens: counted and priced separately from input"; pass=$((pass + 1))
else
  echo "FAIL audit-output-tokens:"; echo "$out"; fail=$((fail + 1))
fi

# Synthetic multi-project corpus for --all and cold-cause attribution.
ROOT="$SCRATCH/projects"
mkdir -p "$ROOT/proj-a" "$ROOT/proj-b" "$ROOT/proj-c" "$ROOT/proj-a/sess1/subagents"
cat > "$ROOT/proj-a/sess1.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","cwd":"/tmp/proj-alpha","message":{"id":"m1","model":"claude-opus-5","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":40000,"input_tokens":5,"output_tokens":700}}}
{"type":"assistant","timestamp":"2026-01-01T00:05:00Z","requestId":"r-m2a","cwd":"/tmp/proj-alpha","message":{"id":"m2","model":"claude-opus-5","usage":{"cache_read_input_tokens":40000,"cache_creation_input_tokens":300,"input_tokens":5}}}
{"type":"assistant","timestamp":"2026-01-01T00:05:01Z","requestId":"r-m2b","cwd":"/tmp/proj-alpha","message":{"id":"m2","model":"claude-opus-5","usage":{"cache_read_input_tokens":40000,"cache_creation_input_tokens":300,"input_tokens":5}}}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-01-01T00:06:00Z","compactMetadata":{"trigger":"manual"}}
{"type":"assistant","timestamp":"2026-01-01T00:08:00Z","cwd":"/tmp/proj-alpha","message":{"id":"m3","model":"claude-opus-5","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":8000,"input_tokens":5}}}
{"type":"assistant","timestamp":"2026-01-01T01:30:00Z","cwd":"/tmp/proj-alpha","message":{"id":"m4","model":"claude-opus-5","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":8200,"input_tokens":5}}}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-01-01T02:00:00Z","compactMetadata":{"trigger":"auto"}}
{"type":"assistant","timestamp":"2026-01-01T03:35:00Z","cwd":"/tmp/proj-alpha","message":{"id":"m5","model":"claude-opus-5","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":9000,"input_tokens":5}}}
{"type":"assistant","timestamp":"2026-01-01T03:40:00Z","cwd":"/tmp/proj-alpha","message":{"id":"m6","model":"claude-sonnet-5","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":5000,"input_tokens":5}}}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-01-01T03:45:00Z","compactMetadata":{"trigger":"manual"}}
{"type":"assistant","timestamp":"2026-01-01T03:50:00Z","cwd":"/tmp/proj-alpha","message":{"id":"m7","model":"claude-sonnet-5","usage":{"cache_read_input_tokens":3000,"cache_creation_input_tokens":9000,"input_tokens":5}}}
EOF
cat > "$ROOT/proj-b/sess2.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-01-02T00:00:00Z","cwd":"/tmp/proj-beta","message":{"id":"n1","model":"claude-opus-5","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":5000,"input_tokens":5,"output_tokens":300}}}
{"type":"assistant","timestamp":"2026-01-02T00:10:00Z","cwd":"/tmp/proj-beta","message":{"id":"n2","model":"claude-opus-5","usage":{"cache_read_input_tokens":5000,"cache_creation_input_tokens":100,"input_tokens":5}}}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-01-02T00:15:00Z"}
{"type":"assistant","timestamp":"2026-01-02T00:20:00Z","cwd":"/tmp/proj-beta","message":{"id":"n3","model":"claude-opus-5","usage":{"cache_read_input_tokens":5100,"cache_creation_input_tokens":6000,"input_tokens":5}}}
EOF
cat > "$ROOT/proj-c/sess3.jsonl" <<'EOF'
{"type":"mode","mode":"normal","sessionId":"sess3"}
{"type":"user","message":{"role":"user","content":"never answered"}}
EOF
cat > "$ROOT/proj-a/sess1/subagents/agent-x.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-01-01T00:01:00Z","isSidechain":true,"cwd":"/tmp/proj-alpha","message":{"id":"z1","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":77777,"input_tokens":5}}}
EOF

# Attribution in the single-session audit: every cause the transcript
# supports (incl. a compact-explained PARTIAL), ambiguity labeled, plain
# inactivity left unsuffixed.
out=$(./warmline-audit "$ROOT/proj-a/sess1.jsonl")
if [[ "$out" == *"7 API turns"* && "$out" == *"<- session start"* \
   && "$out" == *"<- model change"* \
   && "$out" == *"<- inactivity+compact"* && "$out" != *"<- inactivity"$'\n'* \
   && "$out" == *"COLD(rebuilt)  <- /compact"* \
   && "$out" == *"PARTIAL  <- /compact"* \
   && "$out" == *"causes:"* ]]; then
  echo "ok   attribution: causes labeled, dedup by message.id"; pass=$((pass + 1))
else
  echo "FAIL attribution:"; echo "$out"; fail=$((fail + 1))
fi

# --all: discovery (skips subagents + turnless sessions), ranking by
# avoidable cold tokens, totals, cause census.
out=$(./warmline-audit --all "$ROOT")
if [[ "$out" == *"2 sessions under"* && "$out" == *"1 more without API turns"* \
   && "$out" == *"30,200"* && "$out" != *"77,777"* \
   && "$out" == *"/compact 2"* && "$out" == *"inactivity 1"* \
   && "$out" == *"inactivity+compact 1"* && "$out" == *"model change 1"* \
   && "$out" == *"session start 2"* \
   && $(echo "$out" | grep -n proj-alpha | cut -d: -f1) -lt \
      $(echo "$out" | grep -n proj-beta | cut -d: -f1) ]]; then
  echo "ok   all: 2 audited, ranked, subagent excluded, causes counted"; pass=$((pass + 1))
else
  echo "FAIL all:"; echo "$out"; fail=$((fail + 1))
fi

# --all percentages: every cause carries its share of cold-cause events
# (8 total: /compact 2 -> 25%), the cold-events line its share of turns,
# and each session row its share of all avoidable cold tokens (alpha holds
# all 30,200 -> 100%; beta none -> 0%).
if [[ "$out" == *"/compact 2 (25%)"* && "$out" == *"-- 60% of all turns"* \
   && "$out" == *"share"* \
   && "$(echo "$out" | grep proj-alpha)" == *"100%"* \
   && "$(echo "$out" | grep proj-beta)" == *"0%"* ]]; then
  echo "ok   all-pct: cause, cold-event and avoidable shares shown"; pass=$((pass + 1))
else
  echo "FAIL all-pct:"; echo "$out"; fail=$((fail + 1))
fi

# A boundary without compactMetadata is still certainly a compaction, but
# manual-vs-auto would be a guess: generic "compact", never "/compact".
out=$(./warmline-audit "$ROOT/proj-b/sess2.jsonl")
if [[ "$out" == *"PARTIAL  <- compact"* && "$out" != *"/compact"* ]]; then
  echo "ok   degenerate-marker: generic compact, not a guessed trigger"; pass=$((pass + 1))
else
  echo "FAIL degenerate-marker:"; echo "$out"; fail=$((fail + 1))
fi

# `claude upgrade`: every entry records the Claude Code build that wrote it,
# and a build change between consecutive turns is a proven prefix rewrite
# (new system prompt, new tools). Same model throughout, so only the version
# proof can claim this rebuild.
AUPG="$SCRATCH/audit-upgrade.jsonl"
cat > "$AUPG" <<'EOF'
{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","version":"2.1.100","message":{"id":"u1","model":"claude-opus-5","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":20000,"input_tokens":5}}}
{"type":"assistant","timestamp":"2026-01-01T00:02:00Z","version":"2.1.100","message":{"id":"u2","model":"claude-opus-5","usage":{"cache_read_input_tokens":20000,"cache_creation_input_tokens":300,"input_tokens":5}}}
{"type":"assistant","timestamp":"2026-01-01T00:04:00Z","version":"2.1.200","message":{"id":"u3","model":"claude-opus-5","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":21000,"input_tokens":5}}}
EOF
out=$(./warmline-audit "$AUPG")
if [[ "$out" == *"COLD(rebuilt)  <- claude upgrade"* \
   && "$out" == *"claude upgrade 1"* ]]; then
  echo "ok   upgrade-cause: a build change between turns is attributed"; pass=$((pass + 1))
else
  echo "FAIL upgrade-cause:"; echo "$out"; fail=$((fail + 1))
fi

# Same build throughout: nothing for the version proof to claim, so the
# rebuild falls through to unknown exactly as before.
ASAMEV="$SCRATCH/audit-samever.jsonl"
sed 's/2\.1\.200/2.1.100/' "$AUPG" > "$ASAMEV"
out=$(./warmline-audit "$ASAMEV")
if [[ "$out" == *"COLD(rebuilt)  <- unknown"* && "$out" != *"claude upgrade"* ]]; then
  echo "ok   upgrade-same: unchanged version claims nothing"; pass=$((pass + 1))
else
  echo "FAIL upgrade-same:"; echo "$out"; fail=$((fail + 1))
fi

# Model change and build change on the same cold turn: both prove a prefix
# rewrite; model change is the documented winner, so the report never flips
# between the two proofs.
ABOTH="$SCRATCH/audit-bothchange.jsonl"
sed '3s/claude-opus-5/claude-sonnet-5/' "$AUPG" > "$ABOTH"
out=$(./warmline-audit "$ABOTH")
if [[ "$out" == *"COLD(rebuilt)  <- model change"* && "$out" != *"claude upgrade"* ]]; then
  echo "ok   upgrade-vs-model: model change wins the tie, deterministically"; pass=$((pass + 1))
else
  echo "FAIL upgrade-vs-model:"; echo "$out"; fail=$((fail + 1))
fi

# Transcripts that predate version recording carry no field at all; absence
# is not evidence, so the rebuild grades unknown exactly as it always did.
ANOVER="$SCRATCH/audit-nover.jsonl"
python3 - "$AUPG" "$ANOVER" <<'PY'
import json, sys
out = open(sys.argv[2], "w")
for line in open(sys.argv[1]):
    e = json.loads(line)
    del e["version"]
    out.write(json.dumps(e) + "\n")
PY
out=$(./warmline-audit "$ANOVER")
if [[ "$out" == *"COLD(rebuilt)  <- unknown"* && "$out" != *"claude upgrade"* ]]; then
  echo "ok   upgrade-nofield: missing version behaves as before (unknown)"; pass=$((pass + 1))
else
  echo "FAIL upgrade-nofield:"; echo "$out"; fail=$((fail + 1))
fi

# --all --price: the TOTAL row itself carries the premium (30200 avoidable
# * 1.9 * $10/MTok = $0.57), the estimate disclaimer prints, and the notes
# say which side of the input/output split the premium lives on.
out=$(./warmline-audit --all --price 10 "$ROOT")
if [[ "$(echo "$out" | grep '^TOTAL')" == *'$0.57'* && "$out" == *"not billing data"* \
   && "$out" == *'input $10/MTok as given on the command line'* \
   && "$out" == *"per session's own cache bucket"* && "$out" == *"input-side only"* \
   && "$out" == *'$50/MTok warm or cold'* ]]; then
  echo "ok   all-price: TOTAL premium \$0.57, input/output split labeled"; pass=$((pass + 1))
else
  echo "FAIL all-price:"; echo "$out"; fail=$((fail + 1))
fi

# Across projects there is no single right price -- an Opus project and a
# Sonnet one bill differently -- so each session is priced at the rate
# derived for its own project: identical transcripts, 2x apart in premium.
PROOT="$SCRATCH/priced"
mkdir -p "$PROOT/-tmp-priced-a" "$PROOT/-tmp-priced-b"
for p in a b; do
  python3 - "$AUDIT_T" "$PROOT/-tmp-priced-$p/sess.jsonl" "/tmp/priced-$p" <<'PY'
import json, sys
out = open(sys.argv[2], "w")
for line in open(sys.argv[1]):
    e = json.loads(line)
    e["cwd"] = sys.argv[3]
    out.write(json.dumps(e) + "\n")
PY
done
out=$(./warmline-audit --all --price "$PROOT")
if [[ "$(echo "$out" | grep 'priced-a')" == *'$0.59'* \
   && "$(echo "$out" | grep 'priced-b')" == *'$0.29'* \
   && "$out" == *"each project's sessions are priced at its own derived rate"* ]]; then
  echo "ok   all-price-per-project: \$10 and \$5 projects priced apart"; pass=$((pass + 1))
else
  echo "FAIL all-price-per-project:"; echo "$out"; fail=$((fail + 1))
fi

# --all --json --price: machine-readable, correct ordering, totals, premiums.
out=$(./warmline-audit --all --json --price 10 "$ROOT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert len(d["sessions"]) == 2, d
assert d["sessions"][0]["project"] == "proj-alpha"
assert d["sessions"][0]["avoidable_premium_usd"] == 0.57
assert d["sessions"][1]["avoidable_cold_tokens"] == 0
assert d["sessions"][1]["avoidable_premium_usd"] == 0
assert d["total"]["turns"] == 10
assert d["total"]["avoidable_cold_tokens"] == 30200
assert d["total"]["tokens_recached_cold"] == 75200
assert d["total"]["avoidable_premium_usd"] == 0.57
assert d["total"]["skipped"] == 1
assert d["sessions"][0]["tokens_output"] == 700
assert d["total"]["tokens_output"] == 1000
assert d["total"]["price_in_per_mtok"] == 10
assert d["total"]["price_out_per_mtok"] == 50
print("json-ok")')
if [[ "$out" == "json-ok" ]]; then
  echo "ok   all-json: sessions ranked, totals and premiums correct"; pass=$((pass + 1))
else
  echo "FAIL all-json: $out"; fail=$((fail + 1))
fi

# --help used to be read as a transcript path and die, which is how --json
# stayed undiscoverable: an agent auditing itself wants the machine-readable
# form, and the only place to learn it exists is the help text.
out=$(./warmline-audit --help); rc=$?
rc2=0; ./warmline-audit -h >/dev/null 2>&1 || rc2=$?
if [[ "$rc" == 0 && "$rc2" == 0 && "$out" == *"--json"* && "$out" == *"--all"* \
   && "$out" == *"--live"* && "$out" == *"--price"* && "$out" != *"no transcript found"* ]]; then
  echo "ok   audit-help: --help documents --json and friends, exit 0"; pass=$((pass + 1))
else
  echo "FAIL audit-help: rc=$rc rc2=$rc2"; echo "$out" | head -3; fail=$((fail + 1))
fi

# One corrupt timestamp must not kill a cross-session audit.
mkdir -p "$ROOT/proj-d"
printf '%s\n' '{"type":"assistant","timestamp":"not-a-time","cwd":"/tmp/proj-d","message":{"id":"x1","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":1,"input_tokens":5}}}' \
  > "$ROOT/proj-d/sess4.jsonl"
out=$(./warmline-audit --all "$ROOT")
if [[ "$out" == *"2 sessions under"* ]]; then
  echo "ok   corrupt-ts: bad line skipped, --all survives"; pass=$((pass + 1))
else
  echo "FAIL corrupt-ts:"; echo "$out"; fail=$((fail + 1))
fi

# TTL auto-detect: cache writes recorded in the 5m bucket grade the session
# against a 5m TTL (a 7m gap becomes COLD(ttl)); --ttl still forces one.
A5="$SCRATCH/audit-5m.jsonl"
cat > "$A5" <<'EOF'
{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"id":"q1","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":9000,"input_tokens":5,"cache_creation":{"ephemeral_5m_input_tokens":9000,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","timestamp":"2026-01-01T00:07:00Z","message":{"id":"q2","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":9100,"input_tokens":5,"cache_creation":{"ephemeral_5m_input_tokens":9100,"ephemeral_1h_input_tokens":0}}}}
EOF
out=$(./warmline-audit "$A5")
out2=$(./warmline-audit --ttl 60 "$A5")
if [[ "$out" == *"(ttl 5m, from its cache buckets)"* && "$out" == *"COLD(ttl) 1"* \
   && "$out2" == *"(ttl 60m, forced)"* && "$out2" == *"COLD(rebuilt) 2"* ]]; then
  echo "ok   audit-ttl-auto: 5m bucket detected, --ttl forces"; pass=$((pass + 1))
else
  echo "FAIL audit-ttl-auto:"; echo "$out"; echo "$out2"; fail=$((fail + 1))
fi

# --live: warmth is computed from last-turn timestamps against each
# session's own TTL. A 10m-old 1h-bucket session is WARM; the same age on
# the 5m bucket is already cold; a 3h-old session is cold; warm rows sort
# first.
LROOT="$SCRATCH/live-projects"
mkdir -p "$LROOT/proj-warm" "$LROOT/proj-shortttl" "$LROOT/proj-stale"
python3 - "$LROOT" <<'PY'
import datetime, json, os, sys
root = sys.argv[1]
now = datetime.datetime.now(datetime.timezone.utc)
def entry(name, mins_ago, mid, cc):
    u = {"cache_read_input_tokens": 50000, "cache_creation_input_tokens": 500,
         "input_tokens": 5}
    if cc:
        u["cache_creation"] = cc
    return json.dumps({
        "type": "assistant",
        "timestamp": (now - datetime.timedelta(minutes=mins_ago)
                      ).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "cwd": "/tmp/" + name, "message": {"id": mid, "usage": u}}) + "\n"
w = open(os.path.join(root, "proj-warm", "s-warm.jsonl"), "w")
w.write(entry("proj-warm", 40, "w1", None))
w.write(entry("proj-warm", 10, "w2",
              {"ephemeral_1h_input_tokens": 500, "ephemeral_5m_input_tokens": 0}))
open(os.path.join(root, "proj-shortttl", "s-short.jsonl"), "w").write(
    entry("proj-shortttl", 10, "s1",
          {"ephemeral_5m_input_tokens": 500, "ephemeral_1h_input_tokens": 0}))
open(os.path.join(root, "proj-stale", "s-stale.jsonl"), "w").write(
    entry("proj-stale", 180, "x1", None))
PY
out=$(./warmline-audit --live --json "$LROOT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
s = {r["project"]: r for r in d["sessions"]}
assert len(s) == 3, s
assert s["proj-warm"]["warm"] is True and s["proj-warm"]["ttl_min"] == 60
assert 44 <= s["proj-warm"]["minutes_left"] <= 51, s["proj-warm"]
assert s["proj-shortttl"]["warm"] is False and s["proj-shortttl"]["ttl_min"] == 5
assert s["proj-stale"]["warm"] is False
assert d["sessions"][0]["project"] == "proj-warm"
print("live-ok")')
out2=$(./warmline-audit --live "$LROOT")
if [[ "$out" == "live-ok" && "$out2" == *"WARM  cold ~"* \
   && "$out2" == *"cold  since"* && "$out2" == *"3 sessions"* ]]; then
  echo "ok   live: per-session ttl, warm first, text and json agree"; pass=$((pass + 1))
else
  echo "FAIL live: $out"; echo "$out2"; fail=$((fail + 1))
fi

# ---- installer + warmline CLI (isolated via CLAUDE_CONFIG_DIR / WARMLINE_BIN_DIR) ----
IROOT="$(mktemp -d)"
IBIN="$(mktemp -d)"
trap 'rm -rf "$SCRATCH" "$IROOT" "$IBIN"' EXIT
MB='<!-- >>> claude-warmline keep-warm >>> -->'
ME='<!-- <<< claude-warmline keep-warm <<< -->'
inst() { CLAUDE_CONFIG_DIR="$IROOT" WARMLINE_BIN_DIR="$IBIN" ./install.sh "$@"; }
wl()   { CLAUDE_CONFIG_DIR="$IROOT" "$IBIN/warmline" "$@"; }

# The checkout CLI before any install: everything OFF, read-only, keep-warm
# status exits 1.
out=$(CLAUDE_CONFIG_DIR="$IROOT" ./warmline status)
rc=0; CLAUDE_CONFIG_DIR="$IROOT" ./warmline keep-warm status >/dev/null || rc=$?
if [[ "$(echo "$out" | grep statusline)" == *" OFF "* \
   && "$(echo "$out" | grep keep-warm)" == *" OFF "* \
   && "$out" == *"60m fallback"* && "$rc" == 1 \
   && -z "$(ls -A "$IROOT")" ]]; then
  echo "ok   cli-pre-install: all OFF, exit 1, nothing created"; pass=$((pass + 1))
else
  echo "FAIL cli-pre-install: rc=$rc"; echo "$out"; fail=$((fail + 1))
fi

# Fresh install provides the warmline command, the auditor, the statusline,
# the policy copy -- and warns that the bin dir isn't on PATH (mktemp isn't).
out=$(inst)
if [[ -x "$IBIN/warmline" && -x "$IBIN/warmline-audit" \
   && -x "$IROOT/warmline-statusline.py" && -f "$IROOT/warmline-keep-warm.md" ]] \
   && grep -qF "warmline-statusline.py" "$IROOT/settings.json" \
   && [[ "$out" == *"not on your PATH"* && "$out" == *"export PATH="* ]]; then
  echo "ok   ins-fresh: warmline + auditor + statusline + policy, PATH note"; pass=$((pass + 1))
else
  echo "FAIL ins-fresh:"; echo "$out"; fail=$((fail + 1))
fi

# The wired statusLine self-refreshes while idle: refreshInterval 60 by
# default, a hand-tuned value survives reinstall, WARMLINE_REFRESH_SEC=0
# removes it, and `warmline status` reports each state.
ri() { python3 -c 'import json, sys
print(json.load(open(sys.argv[1]))["statusLine"].get("refreshInterval"))' "$IROOT/settings.json"; }
r60=$(ri); out=$(wl status)
python3 - "$IROOT/settings.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["statusLine"]["refreshInterval"] = 25
json.dump(d, open(p, "w"), indent=2)
PY
inst >/dev/null; r25=$(ri)
CLAUDE_CONFIG_DIR="$IROOT" WARMLINE_BIN_DIR="$IBIN" WARMLINE_REFRESH_SEC=0 ./install.sh >/dev/null
r0=$(ri); out0=$(wl status)
inst >/dev/null   # back to the default for the tests below
if [[ "$r60" == 60 && "$out" == *"every 60s while idle"* && "$r25" == 25 \
   && "$r0" == None && "$out0" == *"event-driven only"* ]]; then
  echo "ok   ins-refresh: 60s default, tuned survives, 0 removes, status reports"; pass=$((pass + 1))
else
  echo "FAIL ins-refresh: r60=$r60 r25=$r25 r0=$r0"; echo "$out"; echo "$out0"; fail=$((fail + 1))
fi

# --ref pins the install to one tag: it is refused unless it names something
# fetchable, it never quietly falls back to the checkout it was run from (a
# release page that installs main's tip is the bug this flag exists to fix),
# and a failed fetch leaves nothing behind.
rc=0; out=$(inst --ref 'v1.0.0; rm -rf /' 2>&1) || rc=$?
rc2=0; out2=$(inst --ref 2>&1) || rc2=$?
rc3=0; out3=$(inst --ref v1.0.0 --uninstall 2>&1) || rc3=$?
rc4=0
out4=$(CLAUDE_CONFIG_DIR="$IROOT" WARMLINE_BIN_DIR="$IBIN" \
       WARMLINE_REF=warmline-no-such-ref ./install.sh 2>&1) || rc4=$?
if [[ "$rc" == 2 && "$out" == *"takes a tag or branch name"* \
   && "$rc2" == 2 && "$out2" == *"--ref needs a tag or branch"* \
   && "$rc3" == 2 && "$out3" == *"work alone"* \
   && "$rc4" == 1 && "$out4" == *"from warmline-no-such-ref"* \
   && "$out4" == *"could not fetch statusline.py"* \
   && -s "$IROOT/warmline-statusline.py" ]] \
   && [[ "$(inst --help)" == *"--ref TAG"* ]]; then
  echo "ok   ins-ref: bad refs refused, a pinned ref fetches instead of copying"; pass=$((pass + 1))
else
  echo "FAIL ins-ref: rc=$rc rc2=$rc2 rc3=$rc3 rc4=$rc4"
  echo "$out"; echo "$out2"; echo "$out3"; echo "$out4"; fail=$((fail + 1))
fi

# Help: top-level lists every subcommand; keep-warm help has the exit codes;
# bare invocations print usage.
out=$(wl --help); out2=$(wl keep-warm --help); out3=$(wl)
if [[ "$out" == *"warmline status"* && "$out" == *"keep-warm on"* \
   && "$out" == *"keep-warm off"* && "$out" == *"keep-warm status"* \
   && "$out" == *"warmline audit"* && "$out" == *"warmline watch"* \
   && "$out" == *"warmline awake"* \
   && "$out2" == *"ON / OFF / INCONSISTENT"* && "$out2" == *"exit 0 / 1 / 2"* \
   && "$out3" == *"warmline status"* ]]; then
  echo "ok   cli-help: subcommands and exit codes documented"; pass=$((pass + 1))
else
  echo "FAIL cli-help:"; echo "$out"; echo "$out2"; fail=$((fail + 1))
fi

# Overall status after a plain install: statusline ON, keep-warm OFF, auditor ON.
out=$(wl status)
if [[ "$(echo "$out" | grep statusline)" == *" ON "* \
   && "$(echo "$out" | grep keep-warm)" == *" OFF "* \
   && "$(echo "$out" | grep auditor)" == *" ON   $IBIN/warmline-audit"* ]]; then
  echo "ok   cli-status-installed: statusline+auditor ON, keep-warm OFF"; pass=$((pass + 1))
else
  echo "FAIL cli-status-installed:"; echo "$out"; fail=$((fail + 1))
fi

# OFF->ON, then ON->ON: idempotent, exactly one block, user text survives.
printf 'text before block\n' > "$IROOT/CLAUDE.md"
out_on=$(wl keep-warm on)
printf 'text after block\n' >> "$IROOT/CLAUDE.md"
out_on2=$(wl keep-warm on)
rc=0; wl keep-warm status >/dev/null || rc=$?
if [[ "$out_on" == *"keep-warm ON"* && "$out_on2" == *"already ON"* \
   && "$(grep -cF "$MB" "$IROOT/CLAUDE.md")" == 1 && "$rc" == 0 ]]; then
  echo "ok   cli-on-idempotent: one block, already-ON on repeat, exit 0"; pass=$((pass + 1))
else
  echo "FAIL cli-on-idempotent: rc=$rc / $out_on / $out_on2"; fail=$((fail + 1))
fi

# Detailed ON status: greppable first line, scope, intact policy.
out=$(wl keep-warm status)
if [[ "$out" == "keep-warm  ON"* && "$out" == *"scope    global"* \
   && "$out" == *"policy   intact"* ]]; then
  echo "ok   cli-status-on: ON, global scope, policy intact"; pass=$((pass + 1))
else
  echo "FAIL cli-status-on:"; echo "$out"; fail=$((fail + 1))
fi

# ON->OFF removes only the block (text before AND after survives); OFF->OFF
# is a no-op; status exits 1.
out_off=$(wl keep-warm off)
out_off2=$(wl keep-warm off)
rc=0; wl keep-warm status >/dev/null || rc=$?
if [[ "$out_off" == *"keep-warm OFF"* && "$out_off2" == *"already OFF"* && "$rc" == 1 ]] \
   && ! grep -qF "$MB" "$IROOT/CLAUDE.md" && ! grep -qF "$ME" "$IROOT/CLAUDE.md" \
   && grep -q 'text before block' "$IROOT/CLAUDE.md" \
   && grep -q 'text after block' "$IROOT/CLAUDE.md"; then
  echo "ok   cli-off-safe: block gone, surrounding text intact, exit 1"; pass=$((pass + 1))
else
  echo "FAIL cli-off-safe: rc=$rc / $out_off / $out_off2"; fail=$((fail + 1))
fi

# Malformed block (end marker hand-deleted): status tells the truth (exit 2),
# on refuses (exit 2), off removes only warmline's orphaned marker.
wl keep-warm on >/dev/null
python3 - "$IROOT/CLAUDE.md" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines(True)
open(p, "w").write("".join(l for l in lines if "claude-warmline keep-warm <<<" not in l))
PY
rc_s=0; out=$(wl keep-warm status) || rc_s=$?
rc_o=0; wl keep-warm on >/dev/null 2>&1 || rc_o=$?
wl keep-warm off >/dev/null 2>&1
if [[ "$rc_s" == 2 && "$out" == *"INCONSISTENT"* \
   && "$out" == *"begin marker without its end marker"* && "$rc_o" == 2 ]] \
   && ! grep -qF "$MB" "$IROOT/CLAUDE.md" \
   && grep -q 'text before block' "$IROOT/CLAUDE.md" \
   && grep -q 'text after block' "$IROOT/CLAUDE.md"; then
  echo "ok   cli-malformed: truthful status, on refused, orphan removed"; pass=$((pass + 1))
else
  echo "FAIL cli-malformed: rc_s=$rc_s rc_o=$rc_o"; echo "$out"; fail=$((fail + 1))
fi

# From nothing: no CLAUDE.md at all, then an empty one -- on works in both.
rm -f "$IROOT/CLAUDE.md"
rc=0; wl keep-warm status >/dev/null || rc=$?
wl keep-warm on >/dev/null
ok_nofile=$([[ "$rc" == 1 ]] && grep -qF "$MB" "$IROOT/CLAUDE.md" \
  && grep -qF "$ME" "$IROOT/CLAUDE.md" && echo yes || echo no)
wl keep-warm off >/dev/null
: > "$IROOT/CLAUDE.md"
wl keep-warm on >/dev/null
if [[ "$ok_nofile" == yes ]] && grep -qF "$MB" "$IROOT/CLAUDE.md"; then
  echo "ok   cli-from-nothing: on works with missing and empty CLAUDE.md"; pass=$((pass + 1))
else
  echo "FAIL cli-from-nothing: ok_nofile=$ok_nofile"; fail=$((fail + 1))
fi

# A hand-edited policy body is still ON (exit 0) but reported as modified;
# off && on refreshes it back to intact.
python3 - "$IROOT/CLAUDE.md" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
open(p, "w").write(t.replace("wakeup", "wakeupX", 1))
PY
rc=0; out=$(wl keep-warm status) || rc=$?
wl keep-warm off >/dev/null && wl keep-warm on >/dev/null
out2=$(wl keep-warm status)
if [[ "$rc" == 0 && "$out" == *"policy   modified"* \
   && "$out2" == *"policy   intact"* ]]; then
  echo "ok   cli-modified-detect: edit reported, refresh restores intact"; pass=$((pass + 1))
else
  echo "FAIL cli-modified-detect: rc=$rc"; echo "$out"; fail=$((fail + 1))
fi

# warmline audit passes through to warmline-audit.
out=$(wl audit "$ROOT/proj-a/sess1.jsonl")
if [[ "$out" == *"7 API turns"* ]]; then
  echo "ok   cli-audit-passthrough: audits via the warmline command"; pass=$((pass + 1))
else
  echo "FAIL cli-audit-passthrough:"; echo "$out"; fail=$((fail + 1))
fi

# Unknown commands exit 2 with a pointer to --help.
rc=0; wl bogus >/dev/null 2>&1 || rc=$?
rc2=0; wl keep-warm bogus >/dev/null 2>&1 || rc2=$?
if [[ "$rc" == 2 && "$rc2" == 2 ]]; then
  echo "ok   cli-unknown: unknown commands rejected with exit 2"; pass=$((pass + 1))
else
  echo "FAIL cli-unknown: rc=$rc rc2=$rc2"; fail=$((fail + 1))
fi

# warmline watch: help documents the loop and the one-shot form; bad flags
# and a non-numeric interval are rejected before any loop starts.
out=$(wl watch --help)
rc=0; wl watch --bogus >/dev/null 2>&1 || rc=$?
rc2=0; wl watch -n abc >/dev/null 2>&1 || rc2=$?
if [[ "$out" == *"-n SECS"* && "$out" == *"--live"* && "$rc" == 2 && "$rc2" == 2 ]]; then
  echo "ok   cli-watch: help shown, bad flags and intervals exit 2"; pass=$((pass + 1))
else
  echo "FAIL cli-watch: rc=$rc rc2=$rc2"; echo "$out"; fail=$((fail + 1))
fi

# warmline awake (no-sleep mode): a stub caffeinate proves the wrapper
# passes -is plus the exact command, and that the inhibition's lifetime IS
# the session's -- the wrapped command's exit code comes straight back
# (that exit is what releases the OS assertion; this is the /exit-cleanup
# guarantee, held by construction rather than by a cleanup handler).
STUB="$SCRATCH/awake-stub"
mkdir -p "$STUB"
cat > "$STUB/caffeinate" <<'EOF'
#!/usr/bin/env bash
echo "$@" > "${AWAKE_LOG:?}"
shift            # drop -is, then become the wrapped command
exec "$@"
EOF
cat > "$STUB/claude" <<'EOF'
#!/usr/bin/env bash
echo claude-default-ran
EOF
chmod +x "$STUB/caffeinate" "$STUB/claude"
AWAKE_LOG="$SCRATCH/awake.log"
rc=0; out=$(AWAKE_LOG="$AWAKE_LOG" PATH="$STUB:$PATH" "$IBIN/warmline" awake \
  sh -c 'echo session-running; exit 7') || rc=$?
if [[ "$rc" == 7 && "$out" == "session-running" \
   && "$(cat "$AWAKE_LOG")" == "-is sh -c echo session-running; exit 7" ]]; then
  echo "ok   cli-awake: caffeinate -is wraps the command, exit propagates"; pass=$((pass + 1))
else
  echo "FAIL cli-awake: rc=$rc out=$out log=$(cat "$AWAKE_LOG" 2>/dev/null)"; fail=$((fail + 1))
fi

# Bare `warmline awake` wraps a claude session by default.
out=$(AWAKE_LOG="$AWAKE_LOG" PATH="$STUB:$PATH" "$IBIN/warmline" awake)
if [[ "$out" == "claude-default-ran" && "$(cat "$AWAKE_LOG")" == "-is claude" ]]; then
  echo "ok   cli-awake-default: bare awake runs claude"; pass=$((pass + 1))
else
  echo "FAIL cli-awake-default: out=$out log=$(cat "$AWAKE_LOG")"; fail=$((fail + 1))
fi

# Help documents the no-sleep contract; unknown flags are rejected before
# anything runs; with no inhibitor on PATH the failure is loud, not silent.
out=$(wl awake --help)
rc=0; wl awake --bogus >/dev/null 2>&1 || rc=$?
NOPATH="$SCRATCH/awake-nopath"
mkdir -p "$NOPATH"
ln -sf "$(command -v bash)" "$NOPATH/bash"
ln -sf "$(command -v python3)" "$NOPATH/python3"
rc2=0; err=$(PATH="$NOPATH" "$IBIN/warmline" awake true 2>&1) || rc2=$?
if [[ "$out" == *"no-sleep"* && "$out" == *"caffeinate"* \
   && "$out" == *"normal sleep behavior returns"* && "$rc" == 2 \
   && "$rc2" == 1 && "$err" == *"no sleep inhibitor"* ]]; then
  echo "ok   cli-awake-edges: help, bad flag exit 2, missing inhibitor loud"; pass=$((pass + 1))
else
  echo "FAIL cli-awake-edges: rc=$rc rc2=$rc2 err=$err"; echo "$out"; fail=$((fail + 1))
fi

# warmline wait-for: the poller half of keep-warm. Each target ends the wait
# on its own, and the loop's minute is scaled down so the heartbeat, the
# timeout and the settle window run for real in about a second each.
WF="$SCRATCH/waitfor"
mkdir -p "$WF"
wf() { WARMLINE_WAITFOR_MIN_SEC=1 wl wait-for -n 1 "$@"; }

sleep 2 & WFPID=$!
out=$(wf --pid "$WFPID" --every 0); rc=$?
if [[ "$rc" == 0 && "$out" == *"pid $WFPID finished after"* ]]; then
  echo "ok   wait-pid: returns when the watched process ends"; pass=$((pass + 1))
else
  echo "FAIL wait-pid: rc=$rc out=$out"; fail=$((fail + 1))
fi

( sleep 1; : > "$WF/done" ) &
out=$(wf --file "$WF/done" --every 0); rc=$?
( sleep 1; printf 'transfer complete\n' >> "$WF/job.log" ) &
: > "$WF/job.log"
out2=$(wf --log "$WF/job.log" --until 'transfer comp' --every 0); rc2=$?
if [[ "$rc" == 0 && "$out" == *"$WF/done finished after"* \
   && "$rc2" == 0 && "$out2" == *"finished after"* ]]; then
  echo "ok   wait-file-log: sentinel file and log pattern both end the wait"; pass=$((pass + 1))
else
  echo "FAIL wait-file-log: rc=$rc/$rc2 out=$out / $out2"; fail=$((fail + 1))
fi

# A detached worker's pidfile, and the zombie case: a child the harness has
# not reaped still answers kill -0, so liveness comes from ps, not kill.
( printf '%s\n' "$BASHPID" > "$WF/w.pid"; sleep 2 ) &
out=$(wf --pidfile "$WF/w.pid" --every 0); rc=$?
if [[ "$rc" == 0 && "$out" == *"pidfile $WF/w.pid finished after"* ]]; then
  echo "ok   wait-pidfile: follows the pid a detached worker wrote"; pass=$((pass + 1))
else
  echo "FAIL wait-pidfile: rc=$rc out=$out"; fail=$((fail + 1))
fi

# A target that never materializes is a launch bug, not a long wait: say so
# in seconds rather than blocking until the timeout hours later.
rc=0;  err=$(wf --pidfile "$WF/never.pid" --every 0 2>&1 >/dev/null) || rc=$?
printf 'not a pid\n' > "$WF/junk.pid"
rc2=0; err2=$(wf --pidfile "$WF/junk.pid" --every 0 2>&1 >/dev/null) || rc2=$?
rc3=0; err3=$(wf --log "$WF/never.log" --until x --every 0 2>&1 >/dev/null) || rc3=$?
if [[ "$rc" == 2 && "$rc2" == 2 && "$rc3" == 2 \
   && "$err" == *"never started"* && "$err2" == *"holds no pid"* \
   && "$err3" == *"never appeared"* ]]; then
  echo "ok   wait-guard: absent or unreadable targets exit 2, not hang"; pass=$((pass + 1))
else
  echo "FAIL wait-guard: rc=$rc/$rc2/$rc3 :: $err | $err2 | $err3"; fail=$((fail + 1))
fi

# Heartbeat inside the TTL while waiting, then giving up: --every prints,
# --every 0 stays silent, and --timeout ends the wait with exit 1.
rc=0;  err=$(wf --file "$WF/nothing" --every 1 --timeout 4 2>&1 >"$WF/beats") || rc=$?
out=$(cat "$WF/beats")
rc2=0; out2=$(wf --file "$WF/nothing" --every 0 --timeout 2 2>/dev/null) || rc2=$?
beats=$(printf '%s\n' "$out" | grep -c "still waiting on")
if [[ "$rc" == 1 && "$beats" -ge 2 && "$err" == *"gave up on"* \
   && "$rc2" == 1 && -z "$out2" ]]; then
  echo "ok   wait-heartbeat: $beats beats then a timeout; --every 0 silent"; pass=$((pass + 1))
else
  echo "FAIL wait-heartbeat: rc=$rc beats=$beats rc2=$rc2 out2=${out2@Q}"; fail=$((fail + 1))
fi

# Help documents the '&' trap that makes this command necessary; every bad
# invocation is rejected before the loop starts.
out=$(wl wait-for --help)
rc=0;  wl wait-for >/dev/null 2>&1 || rc=$?
rc2=0; wl wait-for --pid 1 --file /tmp/x >/dev/null 2>&1 || rc2=$?
rc3=0; wl wait-for --log /tmp/x >/dev/null 2>&1 || rc3=$?
rc4=0; wl wait-for --pid abc >/dev/null 2>&1 || rc4=$?
rc5=0; wl wait-for --pid 1 -n x >/dev/null 2>&1 || rc5=$?
rc6=0; wl wait-for --bogus >/dev/null 2>&1 || rc6=$?
rc7=0; wl wait-for --pid >/dev/null 2>&1 || rc7=$?
if [[ "$out" == *"--pidfile"* && "$out" == *"--until"* \
   && "$out" == *"nohup"* && "$out" == *"exit 0 while the real work runs"* \
   && "$rc$rc2$rc3$rc4$rc5$rc6$rc7" == 2222222 ]]; then
  echo "ok   wait-usage: help covers the '&' trap; bad usage exits 2"; pass=$((pass + 1))
else
  echo "FAIL wait-usage: rcs=$rc$rc2$rc3$rc4$rc5$rc6$rc7"; echo "$out"; fail=$((fail + 1))
fi

# --until-cold: the wake is timed off this session's real expiry, read from
# its own transcript, instead of a schedule guessed in advance. A transcript
# whose last turn is two hours old is already past its 1h deadline.
WFSLUG=$(python3 -c 'import os,re;print(re.sub(r"[^A-Za-z0-9]","-",os.getcwd()))')
mkdir -p "$IROOT/projects/$WFSLUG"
wfsess() { # minutes_ago -> a one-turn transcript ending that long ago
  python3 -c 'import datetime, json, sys
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=float(sys.argv[2]))
print(json.dumps({"type": "assistant", "timestamp": t.strftime("%Y-%m-%dT%H:%M:%SZ"),
                  "requestId": "w1", "cwd": "/tmp/proj",
                  "message": {"usage": {"input_tokens": 5, "cache_read_input_tokens": 0,
                                        "cache_creation_input_tokens": 30000,
                                        "cache_creation": {"ephemeral_1h_input_tokens": 30000}}}}))' \
    _ "$1" > "$IROOT/projects/$WFSLUG/sess.jsonl"
}

wfsess 120
rc=0; out=$(wf --until-cold --every 0 --timeout 5) || rc=$?
sleep 2 & WFPID=$!
wfsess 0
rc2=0; out2=$(wf --pid "$WFPID" --until-cold --every 0 --timeout 5) || rc2=$?
wfsess 120
sleep 3 & WFPID2=$!
rc3=0; out3=$(wf --pid "$WFPID2" --until-cold --every 0 --timeout 5) || rc3=$?
kill "$WFPID2" 2>/dev/null || true
if [[ "$rc" == 3 && "$out" == *"cache deadline reached"* \
   && "$rc2" == 0 && "$out2" == *"pid $WFPID finished"* \
   && "$rc3" == 3 && "$out3" == *"still waiting on pid"* ]]; then
  echo "ok   wait-until-cold: expiry ends the wait (exit 3), a live target wins"; pass=$((pass + 1))
else
  echo "FAIL wait-until-cold: rc=$rc/$rc2/$rc3 :: $out | $out2 | $out3"; fail=$((fail + 1))
fi

# No transcript to read the expiry from is a setup error, and it is worth
# failing on before the wait rather than at the deadline that never comes.
rm -f "$IROOT/projects/$WFSLUG/sess.jsonl"
rc=0; err=$(wf --until-cold --every 0 --timeout 5 2>&1 >/dev/null) || rc=$?
out=$(wl wait-for --help)
if [[ "$rc" == 2 && "$err" == *"can't read this session's cache expiry"* \
   && "$out" == *"--until-cold"* && "$out" == *"cache deadline came first"* ]]; then
  echo "ok   wait-until-cold-guard: unreadable expiry exits 2, help documents 3"; pass=$((pass + 1))
else
  echo "FAIL wait-until-cold-guard: rc=$rc :: $err"; fail=$((fail + 1))
fi

# Installer help: install-side flags only, pointing control at warmline.
out=$(inst --help)
if [[ "$out" == *"--keep-warm"* && "$out" == *"--uninstall"* \
   && "$out" == *"--force"* && "$out" == *"warmline --help"* \
   && "$out" != *"--status"* && "$out" != *"--keep-warm-off"* ]]; then
  echo "ok   ins-help: install flags only, control deferred to warmline"; pass=$((pass + 1))
else
  echo "FAIL ins-help:"; echo "$out"; fail=$((fail + 1))
fi

# A foreign statusLine is refused without --force, replaced (and backed up) with it.
printf '{"statusLine":{"type":"command","command":"/usr/bin/other-line"}}\n' > "$IROOT/settings.json"
if inst >/dev/null 2>&1; then refused=no; else refused=yes; fi
inst --force >/dev/null
if [[ "$refused" == yes && -f "$IROOT/settings.json.warmline-bak" ]] \
   && grep -qF "warmline-statusline.py" "$IROOT/settings.json"; then
  echo "ok   ins-foreign: refused bare, replaced with --force, backup kept"; pass=$((pass + 1))
else
  echo "FAIL ins-foreign: refused=$refused"; fail=$((fail + 1))
fi

# install.sh --keep-warm delegates to the installed warmline CLI.
printf 'my own rules\n' > "$IROOT/CLAUDE.md"
inst --keep-warm >/dev/null
if grep -qF "$MB" "$IROOT/CLAUDE.md" && grep -qF "$ME" "$IROOT/CLAUDE.md"; then
  echo "ok   ins-keep-warm-delegates: enabled through the CLI"; pass=$((pass + 1))
else
  echo "FAIL ins-keep-warm-delegates"; fail=$((fail + 1))
fi

# Upgrading refreshes the block the agent actually reads. Refreshing only
# $POLICY would leave every session following the previous release's policy
# while the statusline still painted a confident green "on".
python3 - "$IROOT/CLAUDE.md" "$MB" "$ME" <<'PY'
import sys
md, mb, me = sys.argv[1:4]
text = open(md).read()
head, rest = text.split(mb, 1)
_, tail = rest.split(me, 1)
open(md, "w").write(head + mb + "\npolicy as shipped in an older release\n" + me + tail)
PY
printf 'policy as shipped in an older release\n' > "$IROOT/warmline-keep-warm.md"
out=$(inst)
if [[ "$out" == *"refreshed the keep-warm block"* ]] \
   && ! grep -q "older release" "$IROOT/CLAUDE.md" \
   && grep -q "Keep the prompt cache warm" "$IROOT/CLAUDE.md" \
   && grep -q 'my own rules' "$IROOT/CLAUDE.md"; then
  echo "ok   ins-policy-refresh: an untouched block is brought up to date"; pass=$((pass + 1))
else
  echo "FAIL ins-policy-refresh:"; echo "$out"; fail=$((fail + 1))
fi

# ...but a block the user edited is theirs. Never rewrite it; say so instead.
python3 - "$IROOT/CLAUDE.md" "$MB" "$ME" <<'PY'
import sys
md, mb, me = sys.argv[1:4]
text = open(md).read()
head, rest = text.split(mb, 1)
_, tail = rest.split(me, 1)
open(md, "w").write(head + mb + "\nMY OWN POLICY, HAND EDITED\n" + me + tail)
PY
printf 'policy as shipped in an older release\n' > "$IROOT/warmline-keep-warm.md"
out=$(inst)
if [[ "$out" == *"looks"* && "$out" == *"hand-edited"* \
   && "$out" == *"warmline keep-warm off && warmline keep-warm on"* ]] \
   && grep -q "MY OWN POLICY, HAND EDITED" "$IROOT/CLAUDE.md" \
   && grep -q 'my own rules' "$IROOT/CLAUDE.md"; then
  echo "ok   ins-policy-respects-edits: hand-edited block kept, refresh advised"; pass=$((pass + 1))
else
  echo "FAIL ins-policy-respects-edits:"; echo "$out"; fail=$((fail + 1))
fi
wl keep-warm off >/dev/null && wl keep-warm on >/dev/null   # back to a clean block

# A user who skipped releases has a block that matches neither the current
# policy nor the snapshot just replaced -- but it is still official wording,
# recognized by the embedded hash list. Pull the v1.6.0 text from history so
# the list is tested against what a release actually shipped (needs the tags,
# i.e. a full clone). "ScheduleWakeup" appears only in that old wording.
V16_POLICY="$SCRATCH/policy-v1.6.0.md"
# a shallow clone (CI without full history) or a source tarball has no tags to
# show; skip rather than die, so the suite still runs everywhere it used to
if ! git show v1.6.0:keep-warm.md > "$V16_POLICY" 2>/dev/null; then
  rm -f "$V16_POLICY"
  echo "skip ins-refresh-historical: v1.6.0 not in git history (shallow clone or tarball)"
fi
if [ -s "$V16_POLICY" ]; then
python3 - "$IROOT/CLAUDE.md" "$MB" "$ME" "$V16_POLICY" <<'PY'
import sys
md, mb, me, pol = sys.argv[1:5]
text = open(md).read()
head, rest = text.split(mb, 1)
_, tail = rest.split(me, 1)
open(md, "w").write(head + mb + "\n" + open(pol).read() + me + tail)
PY
out=$(inst)   # $POLICY holds the *current* text, so the prev snapshot can't match
if [[ "$out" == *"refreshed the keep-warm block"* ]] \
   && ! grep -q "ScheduleWakeup" "$IROOT/CLAUDE.md" \
   && grep -q "Keep the prompt cache warm" "$IROOT/CLAUDE.md" \
   && grep -q 'my own rules' "$IROOT/CLAUDE.md"; then
  echo "ok   ins-refresh-historical: a skipped-releases block is brought up to date"; pass=$((pass + 1))
else
  echo "FAIL ins-refresh-historical:"; echo "$out"; fail=$((fail + 1))
fi
fi

# --uninstall removes everything warmline added, keeps the user's own text.
inst --uninstall >/dev/null
if [[ ! -e "$IROOT/warmline-statusline.py" && ! -e "$IBIN/warmline" \
   && ! -e "$IBIN/warmline-audit" && ! -e "$IROOT/warmline-keep-warm.md" ]] \
   && ! grep -q statusLine "$IROOT/settings.json" \
   && ! grep -qF "$MB" "$IROOT/CLAUDE.md" \
   && grep -q 'my own rules' "$IROOT/CLAUDE.md"; then
  echo "ok   ins-uninstall: files, wiring and block removed; own text kept"; pass=$((pass + 1))
else
  echo "FAIL ins-uninstall: leftovers in $IROOT / $IBIN"; fail=$((fail + 1))
fi

# The removed switchboard flags are gone, and modes stay exclusive.
rc1=0; inst --status >/dev/null 2>&1 || rc1=$?
rc2=0; inst --keep-warm-off >/dev/null 2>&1 || rc2=$?
rc3=0; inst --uninstall --keep-warm >/dev/null 2>&1 || rc3=$?
if [[ "$rc1" == 2 && "$rc2" == 2 && "$rc3" == 2 ]]; then
  echo "ok   ins-flags-rejected: --status/--keep-warm-off gone, modes exclusive"; pass=$((pass + 1))
else
  echo "FAIL ins-flags-rejected: rc1=$rc1 rc2=$rc2 rc3=$rc3"; fail=$((fail + 1))
fi

# `warmline setup` is the wiring half of install.sh on its own, for package
# managers: they put the commands on PATH, and a package must never edit the
# user's Claude Code config. It has to work from a prefix layout too, where
# the CLI is a symlink in bin and the data files sit in ../share/warmline.
SROOT="$(mktemp -d)"; SPREFIX="$(mktemp -d)"
mkdir -p "$SPREFIX/bin" "$SPREFIX/share/warmline"
cp warmline warmline-audit "$SPREFIX/bin/"
cp statusline.py keep-warm.md "$SPREFIX/share/warmline/"
mkdir -p "$SPREFIX/linked"; ln -sf "$SPREFIX/bin/warmline" "$SPREFIX/linked/warmline"
setup() { CLAUDE_CONFIG_DIR="$SROOT" "$SPREFIX/linked/warmline" setup "$@"; }
out=$(setup)
if [[ "$out" == *"statusLine wired in"* ]] \
   && [ -x "$SROOT/warmline-statusline.py" ] && [ -f "$SROOT/warmline-keep-warm.md" ] \
   && grep -qF "warmline-statusline.py" "$SROOT/settings.json" \
   && grep -qF '"refreshInterval": 60' "$SROOT/settings.json"; then
  echo "ok   setup-prefix: wires from bin/ + share/warmline through a symlink"; pass=$((pass + 1))
else
  echo "FAIL setup-prefix:"; echo "$out"; fail=$((fail + 1))
fi

# Same refusal contract as the installer: a foreign statusLine needs --force.
printf '{"statusLine":{"type":"command","command":"/usr/bin/other-line"}}\n' > "$SROOT/settings.json"
rc=0; out=$(setup) || rc=$?
rc2=0; setup --force >/dev/null || rc2=$?
if [[ "$rc" == 1 && "$out" == *"re-run with --force"* && "$rc2" == 0 ]] \
   && [ -f "$SROOT/settings.json.warmline-bak" ] \
   && grep -qF "warmline-statusline.py" "$SROOT/settings.json"; then
  echo "ok   setup-foreign: refused bare, replaced with --force, backup kept"; pass=$((pass + 1))
else
  echo "FAIL setup-foreign: rc=$rc rc2=$rc2 :: $out"; fail=$((fail + 1))
fi

# --remove unwires and takes back its own files -- and says what it did not
# touch, because the keep-warm block is a separate decision.
CLAUDE_CONFIG_DIR="$SROOT" "$SPREFIX/linked/warmline" keep-warm on >/dev/null
out=$(setup --remove)
rc=0; setup --remove --force >/dev/null 2>&1 || rc=$?
if [[ "$out" == *"removed statusLine from"* && "$out" == *"keep-warm is still ON"* \
   && "$rc" == 2 ]] \
   && [ ! -e "$SROOT/warmline-statusline.py" ] && [ ! -e "$SROOT/warmline-keep-warm.md" ] \
   && ! grep -q statusLine "$SROOT/settings.json" \
   && grep -qF "$MB" "$SROOT/CLAUDE.md"; then
  echo "ok   setup-remove: unwired, files gone, keep-warm block left and flagged"; pass=$((pass + 1))
else
  echo "FAIL setup-remove: rc=$rc :: $out"; fail=$((fail + 1))
fi

# setup's refresh recognizes historical wording too. --remove above deleted
# $POLICY, so there is no prev snapshot to match either: only the hash list
# can tell this v1.6.0 block from a hand edit.
if [ ! -s "$V16_POLICY" ]; then
  echo "skip setup-refresh-historical: v1.6.0 not in git history (shallow clone or tarball)"
  # the case below asserts this line survives setup's rewrite; the skipped
  # case is what would have written it
  python3 -c 'import sys; p = sys.argv[1]; s = open(p).read(); open(p, "w").write("my setup rules\n" + s)' "$SROOT/CLAUDE.md"
fi
if [ -s "$V16_POLICY" ]; then
python3 - "$SROOT/CLAUDE.md" "$MB" "$ME" "$V16_POLICY" <<'PY'
import sys
md, mb, me, pol = sys.argv[1:5]
text = open(md).read()
head, rest = text.split(mb, 1)
_, tail = rest.split(me, 1)
open(md, "w").write("my setup rules\n" + head + mb + "\n" + open(pol).read() + me + tail)
PY
out=$(setup)
if [[ "$out" == *"refreshed the keep-warm block"* ]] \
   && ! grep -q "ScheduleWakeup" "$SROOT/CLAUDE.md" \
   && grep -q "Keep the prompt cache warm" "$SROOT/CLAUDE.md" \
   && grep -q 'my setup rules' "$SROOT/CLAUDE.md"; then
  echo "ok   setup-refresh-historical: old official wording refreshed in place"; pass=$((pass + 1))
else
  echo "FAIL setup-refresh-historical:"; echo "$out"; fail=$((fail + 1))
fi
fi

# ...while text matching no release -- current, previous, or historical -- is
# a real hand edit, and stays exactly as the user wrote it.
python3 - "$SROOT/CLAUDE.md" "$MB" "$ME" <<'PY'
import sys
md, mb, me = sys.argv[1:4]
text = open(md).read()
head, rest = text.split(mb, 1)
_, tail = rest.split(me, 1)
open(md, "w").write(head + mb + "\nMY OWN SETUP POLICY, HAND EDITED\n" + me + tail)
PY
out=$(setup)
if [[ "$out" == *"looks"* && "$out" == *"hand-edited"* ]] \
   && grep -q "MY OWN SETUP POLICY, HAND EDITED" "$SROOT/CLAUDE.md" \
   && grep -q 'my setup rules' "$SROOT/CLAUDE.md"; then
  echo "ok   setup-respects-edits: hand-edited block kept, refresh advised"; pass=$((pass + 1))
else
  echo "FAIL setup-respects-edits:"; echo "$out"; fail=$((fail + 1))
fi

# No data files anywhere: fail with the fix, don't wire a path to nothing.
rm -f "$SPREFIX/share/warmline/statusline.py"
rc=0; err=$(cd "$SPREFIX" && CLAUDE_CONFIG_DIR="$SROOT" ./linked/warmline setup 2>&1 >/dev/null) || rc=$?
if [[ "$rc" == 1 && "$err" == *"can't find statusline.py"* && "$err" == *"WARMLINE_SHARE_DIR"* ]]; then
  echo "ok   setup-no-source: missing data files exit 1 with the override named"; pass=$((pass + 1))
else
  echo "FAIL setup-no-source: rc=$rc :: $err"; fail=$((fail + 1))
fi
rm -rf "$SROOT" "$SPREFIX"

# install.sh can fetch with wget where curl isn't installed: minimal images
# ship one or the other, and the one-liner on the front page offers both.
if grep -q 'command -v curl' install.sh && grep -q 'wget -qO' install.sh \
   && grep -q 'needs curl or wget' install.sh; then
  echo "ok   ins-wget: curl-or-wget download path"; pass=$((pass + 1))
else
  echo "FAIL ins-wget: install.sh still assumes curl"; fail=$((fail + 1))
fi

# Color gating: piped output carries no ANSI even with the opt-outs unset
# (stdout is not a tty).
out=$(env -u WARMLINE_NO_COLOR ./warmline-audit "$ROOT/proj-a/sess1.jsonl")
if [[ "$out" != *$'\033'* ]]; then
  echo "ok   audit-no-tty: piped output stays plain"; pass=$((pass + 1))
else
  echo "FAIL audit-no-tty: ANSI in piped output"; fail=$((fail + 1))
fi

# WARMLINE_FORCE_COLOR overrides the tty check (green HOT, red COLD(ttl))...
out=$(env -u WARMLINE_NO_COLOR WARMLINE_FORCE_COLOR=1 ./warmline-audit "$ROOT/proj-a/sess1.jsonl")
if [[ "$out" == *$'\033[32m'* && "$out" == *$'\033[31m'* ]]; then
  echo "ok   audit-force-color: ANSI emitted without a tty"; pass=$((pass + 1))
else
  echo "FAIL audit-force-color: no ANSI in: ${out@Q}"; fail=$((fail + 1))
fi

# ...but the opt-outs still win over the force.
out=$(env -u WARMLINE_NO_COLOR NO_COLOR=1 WARMLINE_FORCE_COLOR=1 ./warmline-audit "$ROOT/proj-a/sess1.jsonl")
if [[ "$out" != *$'\033'* ]]; then
  echo "ok   audit-color-precedence: NO_COLOR beats FORCE_COLOR"; pass=$((pass + 1))
else
  echo "FAIL audit-color-precedence: ANSI despite NO_COLOR"; fail=$((fail + 1))
fi

# Cache-health bar: sess1 is 1 HOT of 7 turns; skipped below 5 turns.
out=$(./warmline-audit "$ROOT/proj-a/sess1.jsonl")
if [[ "$out" == *"cache health"* && "$out" == *"14% hot"* \
   && "$out" == *"(1 of 7 turns)"* ]]; then
  echo "ok   health-bar: 14% hot (1 of 7 turns)"; pass=$((pass + 1))
else
  echo "FAIL health-bar:"; echo "$out"; fail=$((fail + 1))
fi
out=$(./warmline-audit "$AUDIT_T")
if [[ "$out" != *"cache health"* ]]; then
  echo "ok   health-bar-skip: no bar under 5 turns"; pass=$((pass + 1))
else
  echo "FAIL health-bar-skip: bar rendered for a 4-turn session"; fail=$((fail + 1))
fi

# Encoding fallback: an ascii-only stdout gets '#'/'.' bars, not a crash.
out=$(PYTHONIOENCODING=ascii ./warmline-audit "$ROOT/proj-a/sess1.jsonl")
if [[ "$out" == *"#"* && "$out" != *"█"* && "$out" == *"cache health"* ]]; then
  echo "ok   ascii-fallback: bars degrade to #"; pass=$((pass + 1))
else
  echo "FAIL ascii-fallback:"; echo "$out"; fail=$((fail + 1))
fi

# --all cause histogram: counts right, bars scaled to the max (2 -> 26
# cells, 1 -> 13), aggregate health bar above the table.
out=$(./warmline-audit --all "$ROOT")
if [[ "$out" == *"where the cold came from"* \
   && "$out" == *$'\n'"  /compact            ██████████████████████████  2"* \
   && "$out" == *$'\n'"  model change        █████████████  1"* \
   && "$out" == *"(2 of 10 turns)"* ]]; then
  echo "ok   histogram: cause bars + aggregate health"; pass=$((pass + 1))
else
  echo "FAIL histogram:"; echo "$out"; fail=$((fail + 1))
fi

# --all --price ends on the prominent avoidable-premium line.
out=$(./warmline-audit --all --price 10 "$ROOT" | tail -1)
if [[ "$out" == 'estimated avoidable premium ~$0.57' ]]; then
  echo "ok   premium-line: $out"; pass=$((pass + 1))
else
  echo "FAIL premium-line: $out"; fail=$((fail + 1))
fi

# --all cold-events summary: corpus totals are 4 rebuilt + 2 ttl.
out=$(./warmline-audit --all "$ROOT")
if [[ "$out" == *"cold events   6  (4 rebuilt, 2 ttl)"* ]]; then
  echo "ok   cold-events: 6 (4 rebuilt, 2 ttl)"; pass=$((pass + 1))
else
  echo "FAIL cold-events:"; echo "$out" | head -5; fail=$((fail + 1))
fi

# Concentration suffix: >5 sessions, avoidable 600k..100k -> top 5 hold
# 2.0M of 2.1M; at $10/MTok that is $38.00 of ~$39.90. With <=5 sessions
# (the main corpus) the premium line must stay bare -- already asserted
# by the premium-line equality test above.
CROOT="$SCRATCH/conc"
i=0
for tok in 600000 500000 400000 300000 200000 100000; do
  i=$((i + 1))
  mkdir -p "$CROOT/proj-$i"
  cat > "$CROOT/proj-$i/sess.jsonl" <<EOF
{"type":"assistant","timestamp":"2026-01-0${i}T00:00:00Z","cwd":"/tmp/conc-$i","message":{"id":"c${i}a","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":1000,"input_tokens":5}}}
{"type":"assistant","timestamp":"2026-01-0${i}T00:05:00Z","cwd":"/tmp/conc-$i","message":{"id":"c${i}b","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":${tok},"input_tokens":5}}}
EOF
done
out=$(./warmline-audit --all --price 10 "$CROOT" | tail -1)
if [[ "$out" == 'estimated avoidable premium ~$39.90  (top 5 sessions: $38.00, other 1: $1.90)' ]]; then
  echo "ok   concentration: top-5 split correct"; pass=$((pass + 1))
else
  echo "FAIL concentration: $out"; fail=$((fail + 1))
fi

# With no path argument, --all discovers transcripts under the configured
# Claude Code config dir (CLAUDE_CONFIG_DIR), not a hardcoded ~/.claude.
mkdir -p "$CLAUDE_CONFIG_DIR/projects/proj-cfg"
cat > "$CLAUDE_CONFIG_DIR/projects/proj-cfg/sess.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","cwd":"/tmp/cfg","message":{"id":"g1","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":1000,"input_tokens":5}}}
{"type":"assistant","timestamp":"2026-01-01T00:05:00Z","cwd":"/tmp/cfg","message":{"id":"g2","usage":{"cache_read_input_tokens":1000,"cache_creation_input_tokens":10,"input_tokens":5}}}
EOF
out=$(./warmline-audit --all)   # local time varies, so match the row loosely
if [[ "$out" == *"1 sessions under $CLAUDE_CONFIG_DIR/projects"* ]] \
   && echo "$out" | grep -qE '^[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}  cfg +2 '; then
  echo "ok   audit-config-dir: --all honors CLAUDE_CONFIG_DIR"; pass=$((pass + 1))
else
  echo "FAIL audit-config-dir:"; echo "$out" | head -3; fail=$((fail + 1))
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
