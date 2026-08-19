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

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
