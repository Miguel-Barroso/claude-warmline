#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

export WARMLINE_STATE_DIR="$(mktemp -d)"
export WARMLINE_NO_COLOR=1
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

# --price: 61,000 cold tokens at $10/MTok base input -> 61000*1.9*10/1e6;
# the avoidable premium counts only the non-session-start cold write (31,000).
out=$(./warmline-audit --price 10 "$AUDIT_T")
if [[ "$out" == *'cost ~$1.16 more'* \
   && "$out" == *'estimated avoidable premium ~$0.59'* ]]; then
  echo "ok   audit-price: cold cost \$1.16, avoidable premium \$0.59"; pass=$((pass + 1))
else
  echo "FAIL audit-price: expected '~\$1.16' and '~\$0.59' in:"; echo "$out"; fail=$((fail + 1))
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
   && "$out" == *"60m (default)"* && "$rc" == 1 \
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

# Help: top-level lists every subcommand; keep-warm help has the exit codes;
# bare invocations print usage.
out=$(wl --help); out2=$(wl keep-warm --help); out3=$(wl)
if [[ "$out" == *"warmline status"* && "$out" == *"keep-warm on"* \
   && "$out" == *"keep-warm off"* && "$out" == *"keep-warm status"* \
   && "$out" == *"warmline audit"* \
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
