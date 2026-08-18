#!/usr/bin/env bash
set -euo pipefail

# claude-warmline installer.
#
#   ./install.sh                     # from a checkout
#   curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash
#
# Flags:
#   --keep-warm    also append the keep-cache-warm policy to ~/.claude/CLAUDE.md
#   --force        replace an existing non-warmline statusLine in settings.json
#   --uninstall    remove everything this installer added

REPO_RAW="https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DEST="$CLAUDE_DIR/warmline-statusline.py"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
STATE_DIR="$CLAUDE_DIR/warmline-state"
MARK_BEGIN="<!-- >>> claude-warmline keep-warm >>> -->"
MARK_END="<!-- <<< claude-warmline keep-warm <<< -->"

KEEP_WARM=0 FORCE=0 UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --keep-warm) KEEP_WARM=1 ;;
    --force) FORCE=1 ;;
    --uninstall) UNINSTALL=1 ;;
    *) echo "unknown flag: $arg (known: --keep-warm --force --uninstall)" >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null || { echo "claude-warmline needs python3 on PATH" >&2; exit 1; }

if [ "$UNINSTALL" = 1 ]; then
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
  rm -f "$DEST"
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

mkdir -p "$CLAUDE_DIR"

# Prefer local files when run from a checkout; fall back to raw GitHub
# when piped through curl | bash.
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/statusline.py" ]; then
  cp "$SRC_DIR/statusline.py" "$DEST"
else
  curl -fsSL "$REPO_RAW/statusline.py" -o "$DEST"
fi
chmod +x "$DEST"
echo "installed $DEST"

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
d["statusLine"] = {"type": "command", "command": dest}
with open(path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
print(f"statusLine wired in {path}")
PY

if [ "$KEEP_WARM" = 1 ]; then
  if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/keep-warm.md" ]; then
    BODY="$(cat "$SRC_DIR/keep-warm.md")"
  else
    BODY="$(curl -fsSL "$REPO_RAW/keep-warm.md")"
  fi
  touch "$CLAUDE_MD"
  if grep -qF "$MARK_BEGIN" "$CLAUDE_MD"; then
    echo "keep-warm block already present in $CLAUDE_MD"
  else
    printf '\n%s\n%s\n%s\n' "$MARK_BEGIN" "$BODY" "$MARK_END" >> "$CLAUDE_MD"
    echo "keep-warm policy appended to $CLAUDE_MD"
  fi
fi

echo
echo "Done. Claude Code usually picks the statusline up within a few seconds;"
echo "restart the session if it doesn't. Verify the script itself with:"
echo "  echo '{\"model\":{\"display_name\":\"Test\"}}' | $DEST"
