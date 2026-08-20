#!/usr/bin/env bash
set -euo pipefail

# claude-warmline installer.
#
#   ./install.sh                     # from a checkout
#   curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash
#
# Installs, updates, uninstalls. Post-install control lives in the
# `warmline` command (warmline --help).

REPO_RAW="https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
BIN_DIR="${WARMLINE_BIN_DIR:-$HOME/.local/bin}"
DEST="$CLAUDE_DIR/warmline-statusline.py"
CLI="$BIN_DIR/warmline"
AUDIT="$BIN_DIR/warmline-audit"
POLICY="$CLAUDE_DIR/warmline-keep-warm.md"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
STATE_DIR="$CLAUDE_DIR/warmline-state"
MARK_BEGIN="<!-- >>> claude-warmline keep-warm >>> -->"
MARK_END="<!-- <<< claude-warmline keep-warm <<< -->"

usage() {
  cat <<EOF
claude-warmline installer: installs, updates, uninstalls.
Post-install control lives in the warmline command (warmline --help).

  ./install.sh              install or update everything
  ./install.sh --keep-warm  install/update, then turn the keep-warm policy ON
  ./install.sh --force      with install: replace a foreign statusLine
  ./install.sh --uninstall  remove everything this installer added
  ./install.sh --help       this text

Installs the statusline to $CLAUDE_DIR, the warmline and
warmline-audit commands to $BIN_DIR (override: WARMLINE_BIN_DIR).

Piped through curl, flags go after 'bash -s --':
  curl -fsSL $REPO_RAW/install.sh | bash -s -- --keep-warm
EOF
}

KEEP_WARM=0 FORCE=0 MODE=install NMODES=0
for arg in "$@"; do
  case "$arg" in
    --keep-warm) KEEP_WARM=1 ;;
    --force) FORCE=1 ;;
    --uninstall) MODE=uninstall; NMODES=$((NMODES + 1)) ;;
    --help|-h)   MODE=help;      NMODES=$((NMODES + 1)) ;;
    *) echo "unknown flag: $arg (see --help)" >&2; exit 2 ;;
  esac
done
if [ "$NMODES" -gt 1 ] || { [ "$MODE" != install ] && [ $((KEEP_WARM + FORCE)) -gt 0 ]; }; then
  echo "--uninstall and --help each work alone (see --help)" >&2
  exit 2
fi

if [ "$MODE" = help ]; then
  usage
  exit 0
fi

command -v python3 >/dev/null || { echo "claude-warmline needs python3 on PATH" >&2; exit 1; }

if [ "$MODE" = uninstall ]; then
  if [ -f "$SETTINGS" ]; then
    DEST="$DEST" python3 - "$SETTINGS" <<'PY'
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    d = json.load(f)
sl = d.get("statusLine") or {}
if os.environ["DEST"] in str(sl.get("command", "")):
    del d["statusLine"]
    with open(path, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    print(f"removed statusLine from {path}")
PY
  fi
  rm -f "$DEST" "$CLI" "$AUDIT" "$POLICY"
  rm -rf "$STATE_DIR"
  if [ -f "$CLAUDE_MD" ]; then
    MB="$MARK_BEGIN" ME="$MARK_END" python3 - "$CLAUDE_MD" <<'PY'
import os, sys
path = sys.argv[1]
text = open(path).read()
mb, me = os.environ["MB"], os.environ["ME"]
if mb in text and me in text:
    head, rest = text.split(mb, 1)
    _, tail = rest.split(me, 1)
    open(path, "w").write(head.rstrip() + "\n" + tail.lstrip("\n"))
    print(f"removed keep-warm block from {path}")
PY
  fi
  echo "claude-warmline uninstalled."
  exit 0
fi

mkdir -p "$CLAUDE_DIR" "$BIN_DIR"

# Prefer local files when run from a checkout; fall back to raw GitHub
# when piped through curl | bash.
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
fetch() { # repo-file dest
  if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/$1" ]; then
    cp "$SRC_DIR/$1" "$2"
  else
    curl -fsSL "$REPO_RAW/$1" -o "$2"
  fi
  echo "installed $2"
}
fetch statusline.py "$DEST";    chmod +x "$DEST"
fetch warmline "$CLI";          chmod +x "$CLI"
fetch warmline-audit "$AUDIT";  chmod +x "$AUDIT"
fetch keep-warm.md "$POLICY"

DEST="$DEST" FORCE="$FORCE" python3 - "$SETTINGS" <<'PY'
import json, os, shutil, sys
path, dest = sys.argv[1], os.environ["DEST"]
force = os.environ["FORCE"] == "1"
d = {}
if os.path.exists(path):
    with open(path) as f:
        d = json.load(f)
    shutil.copyfile(path, path + ".warmline-bak")
sl = d.get("statusLine")
if sl and dest not in str(sl.get("command", "")) and not force:
    print(f"settings.json already has a statusLine: {sl.get('command')!r}")
    print("re-run with --force to replace it (backup: settings.json.warmline-bak)")
    sys.exit(1)
# keep whatever the user tuned on warmline's own statusLine block (padding,
# a custom refreshInterval) across reinstalls
new = dict(sl) if isinstance(sl, dict) and dest in str(sl.get("command", "")) else {}
new.update({"type": "command", "command": dest})
# refreshInterval re-runs the statusline every N seconds while the session
# idles (a local repaint, no API traffic), so the gauge can't freeze on a
# stale HOT. WARMLINE_REFRESH_SEC overrides; 0 removes it. Claude Code
# versions without the setting ignore the key and stay event-driven.
refresh = os.environ.get("WARMLINE_REFRESH_SEC")
if refresh is not None:
    try:
        refresh = int(float(refresh))
    except ValueError:
        sys.exit(f"WARMLINE_REFRESH_SEC must be a number, got {refresh!r}")
    if refresh > 0:
        new["refreshInterval"] = refresh
    else:
        new.pop("refreshInterval", None)
else:
    new.setdefault("refreshInterval", 60)
d["statusLine"] = new
with open(path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
r = new.get("refreshInterval")
how = f"self-refreshes every {r}s while idle" if r else "event-driven only"
print(f"statusLine wired in {path}  ({how})")
PY

if [ "$KEEP_WARM" = 1 ]; then
  "$CLI" keep-warm on
fi

echo
echo "Done. Claude Code usually picks the statusline up within a few seconds;"
echo "restart the session if it doesn't. Next:"
echo "  warmline status         # what's on right now"
echo "  warmline keep-warm on   # optional: keep the cache warm through long waits"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo
     echo "note: $BIN_DIR is not on your PATH, so 'warmline' won't resolve yet."
     echo "add this line to your ~/.zshrc or ~/.bashrc (we never edit those for you):"
     printf '  export PATH="%s:$PATH"\n' "$BIN_DIR" ;;
esac
