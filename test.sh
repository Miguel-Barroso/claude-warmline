#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

export WARMLINE_STATE_DIR="$(mktemp -d)"
export WARMLINE_NO_COLOR=1
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

# Colors on by default: a fresh session's HOT should carry the green code.
out=$(printf '%s' "${HOT/t1/t4}" | env -u WARMLINE_NO_COLOR ./statusline.py)
if [[ "$out" == *$'\033[32mcache HOT\033[0m'* ]]; then
  echo "ok   color: green HOT emitted"; pass=$((pass + 1))
else
  echo "FAIL color: no green ANSI code in: ${out@Q}"; fail=$((fail + 1))
fi

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

# --price: 61,000 cold tokens at $10/MTok base input -> 61000*1.9*10/1e6
out=$(./warmline-audit --price 10 "$AUDIT_T" | tail -1)
if [[ "$out" == *'cost ~$1.16 more'* ]]; then
  echo "ok   audit-price: $out"; pass=$((pass + 1))
else
  echo "FAIL audit-price: expected '~\$1.16' in: $out"; fail=$((fail + 1))
fi

# Synthetic multi-project corpus for --all and cold-cause attribution.
ROOT="$WARMLINE_STATE_DIR/projects"
mkdir -p "$ROOT/proj-a" "$ROOT/proj-b" "$ROOT/proj-c" "$ROOT/proj-a/sess1/subagents"
cat > "$ROOT/proj-a/sess1.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","cwd":"/tmp/proj-alpha","message":{"id":"m1","model":"claude-opus-5","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":40000,"input_tokens":5}}}
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
{"type":"assistant","timestamp":"2026-01-02T00:00:00Z","cwd":"/tmp/proj-beta","message":{"id":"n1","model":"claude-opus-5","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":5000,"input_tokens":5}}}
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

# A boundary without compactMetadata is still certainly a compaction, but
# manual-vs-auto would be a guess: generic "compact", never "/compact".
out=$(./warmline-audit "$ROOT/proj-b/sess2.jsonl")
if [[ "$out" == *"PARTIAL  <- compact"* && "$out" != *"/compact"* ]]; then
  echo "ok   degenerate-marker: generic compact, not a guessed trigger"; pass=$((pass + 1))
else
  echo "FAIL degenerate-marker:"; echo "$out"; fail=$((fail + 1))
fi

# --all --price: the TOTAL row itself carries the premium (30200 avoidable
# * 1.9 * $10/MTok = $0.57), and the estimate disclaimer prints.
out=$(./warmline-audit --all --price 10 "$ROOT")
if [[ "$(echo "$out" | grep '^TOTAL')" == *'$0.57'* && "$out" == *"not billing data"* ]]; then
  echo "ok   all-price: TOTAL premium \$0.57, labeled as estimate"; pass=$((pass + 1))
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

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
