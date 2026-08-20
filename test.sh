#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

export WARMLINE_STATE_DIR="$(mktemp -d)"
export WARMLINE_NO_COLOR=1
# the host machine may configure these; the tests assume the defaults
unset WARMLINE_TTL_MIN WARMLINE_REFRESH_SEC WARMLINE_FORCE_COLOR
# an empty config dir, so the keep-warm field of the statusline tests below
# reads a known-OFF state instead of whoever's real ~/.claude/CLAUDE.md
export CLAUDE_CONFIG_DIR="$WARMLINE_STATE_DIR/cfg"
mkdir -p "$CLAUDE_CONFIG_DIR"
trap 'rm -rf "$WARMLINE_STATE_DIR"' EXIT

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

HOT='{"session_id":"t1","model":{"display_name":"Test"},"workspace":{"current_dir":"/tmp/proj"},"context_window":{"used_percentage":42.7,"total_input_tokens":168432,"current_usage":{"cache_read_input_tokens":165000,"cache_creation_input_tokens":2000}}}'
COLD='{"session_id":"t2","model":{"display_name":"Test"},"workspace":{"current_dir":"/tmp/proj"},"context_window":{"used_percentage":81.0,"total_input_tokens":325000,"current_usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":310000}}}'

check hot     "cache HOT"           "$HOT"
check cold    "cache COLD(rebuilt)" "$COLD"
check sparse  "cache ?"             '{"session_id":"t3","model":{"display_name":"Test"}}'
check garbage "bad input"           'not json'

# TTL inference: backdate t1's stamp 75 minutes, render the same session again.
python3 - "$WARMLINE_STATE_DIR/t1.stamp" <<'PY'
import os, sys, time
t = time.time() - 75 * 60
os.utime(sys.argv[1], (t, t))
PY
out=$(printf '%s' "$HOT" | ./statusline.py)
if [[ "$out" == *"cache COLD(ttl?)"* && "$out" == *"gap 75m"* ]]; then
  echo "ok   ttl-gap: $out"; pass=$((pass + 1))
else
  echo "FAIL ttl-gap: expected 'cache COLD(ttl?)' and 'gap 75m' in: $out"; fail=$((fail + 1))
fi

# Session isolation: t2 rendering in between must not reset t1's clock.
python3 - "$WARMLINE_STATE_DIR/t1.stamp" <<'PY'
import os, sys, time
t = time.time() - 75 * 60
os.utime(sys.argv[1], (t, t))
PY
printf '%s' "$COLD" | ./statusline.py >/dev/null
out=$(printf '%s' "$HOT" | ./statusline.py)
if [[ "$out" == *"gap 75m"* ]]; then
  echo "ok   session-isolation: $out"; pass=$((pass + 1))
else
  echo "FAIL session-isolation: t2's render reset t1's gap: $out"; fail=$((fail + 1))
fi

# Idle repaints must not reset the clock: rendering t1 again with the same
# (stale) usage keeps the 75m gap and the COLD(ttl?) verdict on screen.
out=$(printf '%s' "$HOT" | ./statusline.py)
if [[ "$out" == *"cache COLD(ttl?)"* && "$out" == *"gap 75m"* ]]; then
  echo "ok   stale-repaint: $out"; pass=$((pass + 1))
else
  echo "FAIL stale-repaint: repaint reset the idle clock: $out"; fail=$((fail + 1))
fi

# A real API turn (changed usage) is authoritative over the TTL inference,
# and resets the clock so the next repaint shows no gap.
HOT2=${HOT/165000/166000}
out=$(printf '%s' "$HOT2" | ./statusline.py)
out2=$(printf '%s' "$HOT2" | ./statusline.py)
if [[ "$out" == *"cache HOT"* && "$out" == *"gap 75m"* \
   && "$out2" == *"cache HOT"* && "$out2" != *"gap"* ]]; then
  echo "ok   fresh-turn: $out"; pass=$((pass + 1))
else
  echo "FAIL fresh-turn: expected HOT+gap then HOT+no-gap: $out / $out2"; fail=$((fail + 1))
fi

# Expiry countdown: still HOT but the gap is 50m of a 60m TTL.
python3 - "$WARMLINE_STATE_DIR/t1.stamp" <<'PY'
import os, sys, time
t = time.time() - 50 * 60
os.utime(sys.argv[1], (t, t))
PY
out=$(printf '%s' "$HOT2" | ./statusline.py)
if [[ "$out" == *"cache HOT (cold in 10m)"* && "$out" == *"gap 50m"* ]]; then
  echo "ok   countdown: $out"; pass=$((pass + 1))
else
  echo "FAIL countdown: expected 'cache HOT (cold in 10m)': $out"; fail=$((fail + 1))
fi

# Stale-proof HOT: more than 15m from the TTL, the verdict carries the
# absolute wall-clock expiry (exactly stamp mtime + TTL), so a line frozen
# on screen for hours still reads truthfully.
printf '%s' "${HOT/t1/e1}" | ./statusline.py >/dev/null   # first sighting seeds the stamp
python3 - "$WARMLINE_STATE_DIR/e1.stamp" <<'PY'
import os, sys, time
t = time.time() - 20 * 60
os.utime(sys.argv[1], (t, t))
PY
exp=$(python3 -c 'import os, sys, time
print(time.strftime("%H:%M", time.localtime(os.path.getmtime(sys.argv[1]) + 3600)))' \
  "$WARMLINE_STATE_DIR/e1.stamp")
out=$(printf '%s' "${HOT/t1/e1}" | ./statusline.py)
if [[ "$out" == *"cache HOT (cold ~$exp)"* && "$out" == *"gap 20m"* ]]; then
  echo "ok   absolute-expiry: $out"; pass=$((pass + 1))
else
  echo "FAIL absolute-expiry: expected 'cache HOT (cold ~$exp)' in: $out"; fail=$((fail + 1))
fi

# TTL auto-detect: a transcript whose last cache write went to the 5m
# bucket sets the gauge's TTL, so a 7m gap is already COLD(ttl?);
# WARMLINE_TTL_MIN still overrides the sniff.
T5="$WARMLINE_STATE_DIR/t5-transcript.jsonl"
printf '%s\n' '{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":9000,"input_tokens":5,"cache_creation":{"ephemeral_5m_input_tokens":9000,"ephemeral_1h_input_tokens":0}}}}' > "$T5"
HOT5=$(python3 -c 'import json, sys
d = json.loads(sys.argv[1]); d["session_id"] = "t5"; d["transcript_path"] = sys.argv[2]
print(json.dumps(d))' "$HOT" "$T5")
printf '%s' "$HOT5" | ./statusline.py >/dev/null
python3 - "$WARMLINE_STATE_DIR/t5.stamp" <<'PY'
import os, sys, time
t = time.time() - 7 * 60
os.utime(sys.argv[1], (t, t))
PY
out=$(printf '%s' "$HOT5" | ./statusline.py)
out2=$(printf '%s' "$HOT5" | WARMLINE_TTL_MIN=60 ./statusline.py)
if [[ "$out" == *"cache COLD(ttl?)"* && "$out" == *"gap 7m"* \
   && "$out2" == *"cache HOT"* ]]; then
  echo "ok   ttl-sniff: 5m bucket -> COLD(ttl?) at a 7m gap; env override wins"; pass=$((pass + 1))
else
  echo "FAIL ttl-sniff: $out / $out2"; fail=$((fail + 1))
fi

# Colors on by default: a fresh session's HOT should carry the green code.
out=$(printf '%s' "${HOT/t1/t4}" | env -u WARMLINE_NO_COLOR ./statusline.py)
if [[ "$out" == *$'\033[32mcache HOT\033[0m'* ]]; then
  echo "ok   color: green HOT emitted"; pass=$((pass + 1))
else
  echo "FAIL color: no green ANSI code in: ${out@Q}"; fail=$((fail + 1))
fi

# Keep-warm indicator: the same three states the warmline CLI reports, read
# out of CLAUDE.md on every render (no state file), plus the opt-out.
KWMD="$CLAUDE_CONFIG_DIR/CLAUDE.md"
check kw-off "keep-warm off" "${HOT/t1/k1}"     # no CLAUDE.md at all
printf 'user text\n' > "$KWMD"
check kw-off2 "keep-warm off" "${HOT/t1/k2}"    # a CLAUDE.md without the block
printf '%s\npolicy body\n%s\n' \
  '<!-- >>> claude-warmline keep-warm >>> -->' \
  '<!-- <<< claude-warmline keep-warm <<< -->' >> "$KWMD"
check kw-on  "keep-warm on"  "${HOT/t1/k3}"
out=$(printf '%s' "${HOT/t1/k4}" | env -u WARMLINE_NO_COLOR ./statusline.py)
if [[ "$out" == *$'\033[32mkeep-warm on\033[0m'* ]]; then
  echo "ok   kw-color: green keep-warm on emitted"; pass=$((pass + 1))
else
  echo "FAIL kw-color: no green keep-warm in: ${out@Q}"; fail=$((fail + 1))
fi
printf 'user text\n%s\npolicy body\n' \
  '<!-- >>> claude-warmline keep-warm >>> -->' > "$KWMD"   # end marker lost
check kw-malformed "keep-warm ?" "${HOT/t1/k5}"
out=$(printf '%s' "${HOT/t1/k6}" | WARMLINE_NO_KEEPWARM=1 ./statusline.py)
if [[ "$out" != *"keep-warm"* && "$out" == *"cache HOT"* ]]; then
  echo "ok   kw-optout: field omitted"; pass=$((pass + 1))
else
  echo "FAIL kw-optout: $out"; fail=$((fail + 1))
fi
rm -f "$KWMD"

# warmline-audit: synthetic transcript with one of each verdict, a duplicate
# requestId (one API request, two entries) and a sidechain turn to exclude.
AUDIT_T="$WARMLINE_STATE_DIR/audit-test.jsonl"
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
   && "$out" == *'output tokens at $50/MTok'* ]]; then
  echo "ok   audit-price: cold cost \$1.16, premium \$0.59, output at 5x input"; pass=$((pass + 1))
else
  echo "FAIL audit-price: expected '~\$1.16', '~\$0.59', '\$50/MTok' in:"; echo "$out"; fail=$((fail + 1))
fi

# Bare --price prices at the current sheet ($3/MTok input, 5x = $15 output);
# --price-out overrides the output rate independently of the input rate.
out=$(./warmline-audit --price "$AUDIT_T")
out2=$(./warmline-audit --price-in 10 --price-out 25 "$AUDIT_T")
if [[ "$out" == *'at $3/MTok base input'* && "$out" == *'output tokens at $15/MTok'* \
   && "$out" == *'estimated avoidable premium ~$0.18'* \
   && "$out2" == *'at $10/MTok base input'* \
   && "$out2" == *'output tokens at $25/MTok'* ]]; then
  echo "ok   audit-price-defaults: bare --price = \$3/\$15, --price-out overrides"; pass=$((pass + 1))
else
  echo "FAIL audit-price-defaults:"; echo "$out"; echo "$out2"; fail=$((fail + 1))
fi

# Output tokens are summed from the transcript and priced at the output
# rate: 1,000 + 500 output tokens at the default $15/MTok -> ~$0.02.
AOUT="$WARMLINE_STATE_DIR/audit-out.jsonl"
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
ROOT="$WARMLINE_STATE_DIR/projects"
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

# --all --price: the TOTAL row itself carries the premium (30200 avoidable
# * 1.9 * $10/MTok = $0.57), the estimate disclaimer prints, and the notes
# say which side of the input/output split the premium lives on.
out=$(./warmline-audit --all --price 10 "$ROOT")
if [[ "$(echo "$out" | grep '^TOTAL')" == *'$0.57'* && "$out" == *"not billing data"* \
   && "$out" == *'base input $10/MTok'* && "$out" == *"input-side only"* \
   && "$out" == *'$50/MTok warm or cold'* ]]; then
  echo "ok   all-price: TOTAL premium \$0.57, input/output split labeled"; pass=$((pass + 1))
else
  echo "FAIL all-price:"; echo "$out"; fail=$((fail + 1))
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
A5="$WARMLINE_STATE_DIR/audit-5m.jsonl"
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
LROOT="$WARMLINE_STATE_DIR/live-projects"
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
trap 'rm -rf "$WARMLINE_STATE_DIR" "$IROOT" "$IBIN"' EXIT
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
STUB="$WARMLINE_STATE_DIR/awake-stub"
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
AWAKE_LOG="$WARMLINE_STATE_DIR/awake.log"
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
NOPATH="$WARMLINE_STATE_DIR/awake-nopath"
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
CROOT="$WARMLINE_STATE_DIR/conc"
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
