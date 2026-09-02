#!/usr/bin/env bash
set -euo pipefail

# claude-warmline installer.
#
#   ./install.sh                     # from a checkout
#   curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash
#   wget -qO-  https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/TAG/install.sh | bash -s -- --ref TAG
#
# Installs, updates, uninstalls. Post-install control lives in the
# `warmline` command (warmline --help).

REPO="https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline"
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

# Which commit's files to install. Unpinned this is main's tip; a release page
# pins its own tag, so "install v2.0.0" and "install main" stay two different
# commands even in the week they resolve to the same tree.
REF="${WARMLINE_REF:-main}"
PINNED=0
if [ -n "${WARMLINE_REF:-}" ]; then PINNED=1; fi
REPO_RAW="$REPO/$REF"

usage() {
  cat <<EOF
claude-warmline installer: installs, updates, uninstalls.
Post-install control lives in the warmline command (warmline --help).

  ./install.sh              install or update everything
  ./install.sh --keep-warm  install/update, then turn the keep-warm policy ON
  ./install.sh --force      with install: replace a foreign statusLine
  ./install.sh --ref TAG    install that tag or branch instead of main's tip
  ./install.sh --uninstall  remove everything this installer added
  ./install.sh --help       this text

Installs the statusline to $CLAUDE_DIR, the warmline and
warmline-audit commands to $BIN_DIR (override: WARMLINE_BIN_DIR).

Piped through curl or wget, flags go after 'bash -s --':
  curl -fsSL $REPO/main/install.sh | bash -s -- --keep-warm
  wget -qO-  $REPO/main/install.sh | bash -s -- --keep-warm

A pinned install names the tag twice -- once for this script, once for the
files it fetches (WARMLINE_REF=TAG does the same as --ref):
  curl -fsSL $REPO/TAG/install.sh | bash -s -- --ref TAG
EOF
}

KEEP_WARM=0 FORCE=0 MODE=install NMODES=0 REF_FLAG=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-warm) KEEP_WARM=1 ;;
    --force) FORCE=1 ;;
    --ref)
      shift
      [ $# -gt 0 ] || { echo "--ref needs a tag or branch (see --help)" >&2; exit 2; }
      REF="$1"; REF_FLAG=1 ;;
    --ref=*) REF="${1#--ref=}"; REF_FLAG=1 ;;
    --uninstall) MODE=uninstall; NMODES=$((NMODES + 1)) ;;
    --help|-h)   MODE=help;      NMODES=$((NMODES + 1)) ;;
    *) echo "unknown flag: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
if [ "$NMODES" -gt 1 ] || { [ "$MODE" != install ] && [ $((KEEP_WARM + FORCE + REF_FLAG)) -gt 0 ]; }; then
  echo "--uninstall and --help each work alone (see --help)" >&2
  exit 2
fi
if [ "$REF_FLAG" = 1 ]; then PINNED=1; fi
case "$REF" in
  ""|-*|*[!A-Za-z0-9._/-]*)
    echo "--ref takes a tag or branch name, got: '$REF'" >&2; exit 2 ;;
esac
REPO_RAW="$REPO/$REF"

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
# when piped through curl | bash. A pinned ref always goes to the network:
# the checkout you happen to be standing in is not the tag you asked for.
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
# curl if it's there, wget if it isn't: whichever fetched this script is on the
# machine, and neither is guaranteed -- minimal Linux images ship one or the other
download() { # url dest
  if command -v curl >/dev/null; then curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null; then wget -qO "$2" "$1"
  else echo "claude-warmline needs curl or wget on PATH to download files" >&2; exit 1
  fi
}
if [ "$PINNED" = 1 ]; then
  command -v curl >/dev/null || command -v wget >/dev/null || {
    echo "installing a pinned ref needs curl or wget on PATH" >&2; exit 1; }
  echo "installing claude-warmline from $REF"
fi
fetch() { # repo-file dest
  if [ "$PINNED" = 0 ] && [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/$1" ]; then
    cp "$SRC_DIR/$1" "$2"
  else
    # download beside the target, not onto it: a bad ref (or a dropped
    # connection) must not take out the copy already installed
    tmp="$(mktemp)"
    download "$REPO_RAW/$1" "$tmp" || {
      rm -f "$tmp"
      echo "could not fetch $1 from $REF -- is that a real tag or branch?" >&2
      exit 1
    }
    chmod 644 "$tmp"   # mktemp makes it 0600
    mv "$tmp" "$2"
  fi
  echo "installed $2"
}
fetch statusline.py "$DEST";    chmod +x "$DEST"
fetch warmline "$CLI";          chmod +x "$CLI"
fetch warmline-audit "$AUDIT";  chmod +x "$AUDIT"

# the statusline used to infer cache state from per-session stamp files; it
# now reads Claude Code's own prompt_cache fields and keeps no state at all,
# so an upgrade leaves this directory behind as dead weight
if [ -d "$STATE_DIR" ]; then
  rm -rf "$STATE_DIR"
  echo "removed $STATE_DIR (the statusline no longer keeps state)"
fi

# the block already in CLAUDE.md is what the agent actually reads, so an
# upgrade that only refreshes $POLICY leaves every session following the
# previous release's policy. Keep the old text to tell "never touched" (safe
# to rewrite) from "hand-edited" (never rewrite without being asked).
PREV_POLICY=""
if [ -f "$POLICY" ]; then
  PREV_POLICY="$(mktemp)"
  cp "$POLICY" "$PREV_POLICY"
fi
fetch keep-warm.md "$POLICY"

if [ -f "$CLAUDE_MD" ]; then
  MB="$MARK_BEGIN" ME="$MARK_END" PREV="$PREV_POLICY" \
    python3 - "$CLAUDE_MD" "$POLICY" <<'PY'
import hashlib, os, re, sys
md, policy = sys.argv[1], sys.argv[2]
mb, me = os.environ["MB"], os.environ["ME"]
text = open(md).read()
if mb not in text or me not in text:
    sys.exit(0)  # off, or malformed -- `warmline keep-warm status` says which
head, rest = text.split(mb, 1)
body, tail = rest.split(me, 1)
new = open(policy).read()
norm = lambda s: re.sub(r"\s+", " ", s).strip()
if norm(body) == norm(new):
    sys.exit(0)
prev = os.environ.get("PREV") or ""
prev = open(prev).read() if prev and os.path.exists(prev) else None
# Every superseded release's policy wording, as sha256 of the normalized text,
# so skipping releases doesn't turn official text into a "hand edit" the
# refresh below refuses to touch. Only text matching none of these is really
# the user's. Same list in warmline's cmd_setup -- keep the two in sync.
# Regenerate:  git show TAG:keep-warm.md | python3 -c 'import hashlib,re,sys;
#   print(hashlib.sha256(re.sub(r"\s+"," ",sys.stdin.read()).strip().encode()).hexdigest())'
released = {
    "ccf9f481845afd31e6d8e2a7e3a88ed16040b339d05d4c2660c45ad5e67fb106",  # v1.0.0
    "307242b3b057d5f465fa25c54c8d87a883b8b311795fda823bfa2c42e54dfaeb",  # v1.1.0-v1.3.0
    "ccd1d8fef148092d4373758e17ff78c44f99edb6343309c1145542fd88552cc8",  # v1.4.0-v1.6.0
    "5137843bc921531d39d51e597957ebf9074cd7d7b5ab0f9ddd0f2307622d0c69",  # v1.7.0
    "2be2c0965b2b7fdf058578ea8fcf7edbd2b406495828ff4750d0c9bc8461c219",  # v1.8.0-v2.1.0
}
if (prev is not None and norm(body) == norm(prev)) \
        or hashlib.sha256(norm(body).encode("utf-8")).hexdigest() in released:
    open(md, "w").write(head + mb + "\n" + new.rstrip() + "\n" + me + tail)
    print(f"refreshed the keep-warm block in {md} (policy updated)")
else:
    print(f"note: the keep-warm block in {md} differs from the policy just")
    print("installed and does not match the one it replaced, so it looks")
    print("hand-edited -- left untouched. To adopt the new wording, run:")
    print("  warmline keep-warm off && warmline keep-warm on")
PY
fi
if [ -n "$PREV_POLICY" ]; then rm -f "$PREV_POLICY"; fi

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
# idles (a local repaint, no API traffic). Claude Code's own expires_at
# trigger already flips HOT to COLD at the right second -- verified firing on
# 2.1.252 -- but it is a single shot at expiry, so nothing repaints when the
# 15-minute warning window opens. This timer is what turns the line yellow.
# WARMLINE_REFRESH_SEC overrides; 0 removes it and keeps a correct gauge that
# just stops warning first. Versions without the setting ignore the key.
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
