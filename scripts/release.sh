#!/usr/bin/env bash
set -euo pipefail

# claude-warmline release script.
#
#   scripts/release.sh 2.3.0             # or v2.3.0
#   scripts/release.sh 2.3.0 --dry-run   # print every action, execute nothing
#
# Why a script for something this small: the Homebrew cask pins the release
# tarball's sha256, and a tag cannot contain the checksum of its own tarball.
# So every release is a two-step -- tag and push first, then pin the checksum
# into packaging/homebrew/warmline.rb in a follow-up commit to main, then copy
# the pinned cask into the tap. That dance has been done by hand three times;
# this script is the dance, written down.
#
# Every step is idempotent, so a partial failure is resumed by re-running with
# the same version: a tag that already exists is skipped, a sha that is already
# pinned is not re-committed, a tap that already matches is left alone. The one
# thing it will never do is move a published tag -- hard rule in this repo.
#
# Needs git, curl and shasum. brew is only used to find the local tap checkout;
# without it the tap is cloned to a temp dir instead. gh is never required.

OWNER_REPO="Miguel-Barroso/claude-warmline"
TAP_URL="https://github.com/Miguel-Barroso/homebrew-warmline.git"
REPO_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
CASK="$REPO_DIR/packaging/homebrew/warmline.rb"

usage() {
  cat <<EOF
usage: scripts/release.sh X.Y.Z [--dry-run]

Tags vX.Y.Z at HEAD and pushes the tag, waits for GitHub to generate the
release tarball, pins its sha256 into packaging/homebrew/warmline.rb on main,
and copies the pinned cask into the Homebrew tap. Ends with the checklist of
steps that stay manual on purpose.

  --dry-run   print every action; execute nothing that mutates or pushes
EOF
}

VERSION="" DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown flag: $1 (see --help)" >&2; exit 2 ;;
    *)
      [ -z "$VERSION" ] || { echo "one version at a time, got '$VERSION' and '$1'" >&2; exit 2; }
      VERSION="$1" ;;
  esac
  shift
done
[ -n "$VERSION" ] || { usage >&2; exit 2; }
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "that does not look like a version: '$VERSION' (want X.Y.Z)" >&2; exit 2; }
TAG="v$VERSION"
PIN_MSG="packaging: pin the cask's sha256 to the $TAG tarball"
TARBALL_URL="https://github.com/$OWNER_REPO/archive/refs/tags/$TAG.tar.gz"

say() { echo "release: $*"; }
die() { echo "release: error: $*" >&2; exit 1; }

# Every mutating command goes through run(): it is always printed first, and
# under --dry-run printing is all that happens.
run() {
  echo "+ $*"
  [ "$DRY_RUN" = 1 ] || "$@"
}

# A real run refuses at the first bad preflight check -- fail early beats
# untangling a half-pushed release. A dry run flags the refusal and keeps
# walking, so you can see the whole plan (and every blocker, not just the
# first) before anything is at stake.
PREFLIGHT_OK=1
refuse() {
  if [ "$DRY_RUN" = 1 ]; then
    say "preflight: a real run would refuse here: $*"
    PREFLIGHT_OK=0
  else
    die "$*"
  fi
}

command -v git >/dev/null || die "git is required"
command -v curl >/dev/null || die "curl is required"
command -v shasum >/dev/null || die "shasum is required"

if [ "$DRY_RUN" = 1 ]; then
  say "dry run: every action below is printed, none is executed"
fi

# --- preflight ---------------------------------------------------------------

say "== preflight"
cd "$REPO_DIR"

[ -z "$(git status --porcelain)" ] \
  || refuse "the working tree is not clean -- commit or stash before releasing"

branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" = main ] || refuse "releases are cut from main, not '$branch'"

# The fetch runs even under --dry-run: it only updates remote-tracking refs,
# and the checks below are meaningless against a stale view of origin.
say "fetching origin"
git fetch origin

# A published tag is never moved. The one tolerated form of an existing remote
# tag is one that already sits on main's history -- that means a previous run
# of this script got that far and we are resuming, not re-tagging.
TAG_PUBLISHED=0
remote_tag_commit="$(git ls-remote --tags origin \
  | awk -v t="refs/tags/$TAG" '$2 == t || $2 == t"^{}" { c = $1 } END { print c }')"
if [ -n "$remote_tag_commit" ]; then
  if git merge-base --is-ancestor "$remote_tag_commit" HEAD 2>/dev/null; then
    say "tag $TAG is already on origin and on main's history -- resuming after it"
    TAG_PUBLISHED=1
  else
    refuse "tag $TAG already exists on origin and is not on main's history; a published tag is never moved -- pick the next version"
  fi
fi

# Local main must be exactly origin/main, with one exception: a previous run
# may have made the pin commit and died before pushing it. That precise shape
# (ahead by one commit, and it is this release's pin commit) is a resume;
# anything else is a repo state this script should not guess about.
head_commit="$(git rev-parse HEAD)"
remote_main="$(git rev-parse origin/main)"
if [ "$head_commit" != "$remote_main" ]; then
  if git merge-base --is-ancestor "$remote_main" HEAD 2>/dev/null \
     && [ "$(git rev-list --count "$remote_main..HEAD")" = 1 ] \
     && [ "$(git log -1 --format=%s)" = "$PIN_MSG" ]; then
    if [ "$TAG_PUBLISHED" = 1 ]; then
      say "HEAD is origin/main plus an unpushed pin commit -- resuming"
    else
      refuse "found an unpushed pin commit for $TAG but no published tag -- untangle that by hand"
    fi
  else
    refuse "local main is not in sync with origin/main -- push or pull first"
  fi
fi

# --- tag ---------------------------------------------------------------------

say "== tag"
if [ "$TAG_PUBLISHED" = 1 ]; then
  say "tag $TAG is already published -- nothing to create or push"
else
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    # An unpushed local tag is fine if it marks HEAD (a run that died between
    # tagging and pushing); anywhere else it is a leftover to deal with first.
    [ "$(git rev-parse "$TAG^{commit}")" = "$head_commit" ] \
      || die "local tag $TAG exists but does not point at HEAD -- delete it (git tag -d $TAG) if it was a mistake"
    say "tag $TAG already exists locally at HEAD -- skipping creation"
  else
    run git tag -a "$TAG" -m "$TAG"
  fi
  # The explicit refs/tags/ form on purpose: the bare name has collided with a
  # branch ref here before, and this form cannot be ambiguous.
  run git push origin "refs/tags/$TAG"
fi

# --- checksum ----------------------------------------------------------------

say "== checksum"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

if [ "$DRY_RUN" = 1 ]; then
  echo "+ curl -fsSL $TARBALL_URL  (polling until GitHub has generated it)"
  echo "+ shasum -a 256 <tarball>"
  SHA="0000000000000000000000000000000000000000000000000000000000000000"
  say "dry run: continuing with an all-zero placeholder sha256"
else
  # GitHub generates tag tarballs on demand, so the first request right after
  # the push can 404. Poll with short sleeps instead of failing on try one.
  tarball="$tmpdir/$TAG.tar.gz"
  attempt=1
  until curl -fsSL -o "$tarball" "$TARBALL_URL"; do
    [ "$attempt" -lt 10 ] || die "gave up waiting for $TARBALL_URL"
    say "tarball not ready yet (attempt $attempt of 10) -- retrying in 5s"
    attempt=$((attempt + 1))
    sleep 5
  done
  SHA="$(shasum -a 256 "$tarball" | awk '{ print $1 }')"
  say "sha256 $SHA"
fi

# --- pin the cask ------------------------------------------------------------

say "== pin the cask"
[ -f "$CASK" ] || die "cask not found at $CASK"

if grep -q "version \"$VERSION\"" "$CASK" && grep -q "sha256 \"$SHA\"" "$CASK"; then
  say "cask already pins $VERSION with this sha256 -- nothing to edit"
else
  echo "+ set version \"$VERSION\" and sha256 \"$SHA\" in packaging/homebrew/warmline.rb"
  if [ "$DRY_RUN" != 1 ]; then
    # sed -i differs between BSD and GNU; a temp file and mv works on both.
    sed -E \
      -e "s|^(  version \")[^\"]*(\")|\1$VERSION\2|" \
      -e "s|^(  sha256 \")[^\"]*(\")|\1$SHA\2|" \
      "$CASK" > "$CASK.tmp"
    mv "$CASK.tmp" "$CASK"
    grep -q "version \"$VERSION\"" "$CASK" \
      || die "the version line did not take -- has the cask's layout changed?"
    grep -q "sha256 \"$SHA\"" "$CASK" \
      || die "the sha256 line did not take -- has the cask's layout changed?"
  fi
fi

if [ "$DRY_RUN" = 1 ]; then
  echo "+ git add packaging/homebrew/warmline.rb"
  echo "+ git commit -m \"$PIN_MSG\""
  echo "+ git push origin main"
else
  if git diff --quiet -- "$CASK"; then
    say "cask file unchanged -- nothing to commit"
  else
    run git add "$CASK"
    run git commit -m "$PIN_MSG"
  fi
  if [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ]; then
    say "main already matches origin -- nothing to push"
  else
    run git push origin main
  fi
fi

# --- tap ---------------------------------------------------------------------

say "== tap"
TAP_DIR=""
if command -v brew >/dev/null 2>&1; then
  # brew --repository only *computes* the path; the tap is tapped only if the
  # checkout actually exists there.
  candidate="$(brew --repository miguel-barroso/warmline 2>/dev/null || true)"
  if [ -n "$candidate" ] && [ -d "$candidate/.git" ]; then
    TAP_DIR="$candidate"
    say "using the tapped checkout at $TAP_DIR"
  fi
fi
if [ -z "$TAP_DIR" ]; then
  TAP_DIR="$tmpdir/homebrew-warmline"
  say "tap not tapped locally -- cloning it instead"
  run git clone "$TAP_URL" "$TAP_DIR"
fi

if [ ! -d "$TAP_DIR" ]; then
  # Only reachable under --dry-run, when the clone above was print-only.
  echo "+ cp packaging/homebrew/warmline.rb <tap>/Casks/warmline.rb"
  echo "+ git -C <tap> add Casks/warmline.rb && git commit -m \"warmline $VERSION\" && git push"
else
  # The tap's layout is whatever the tap says it is: find the cask that is
  # already there rather than assume; Casks/warmline.rb is the fallback for a
  # tap that has never shipped one.
  tap_cask="$(find "$TAP_DIR" -name warmline.rb -not -path '*/.git/*' | head -n 1)"
  [ -n "$tap_cask" ] || tap_cask="$TAP_DIR/Casks/warmline.rb"

  if [ "$DRY_RUN" = 1 ]; then
    echo "+ cp packaging/homebrew/warmline.rb $tap_cask"
    echo "+ git -C $TAP_DIR add $tap_cask"
    echo "+ git -C $TAP_DIR commit -m \"warmline $VERSION\""
    echo "+ git -C $TAP_DIR push origin HEAD"
  else
    if cmp -s "$CASK" "$tap_cask" 2>/dev/null; then
      say "tap cask already matches -- nothing to copy"
    else
      run mkdir -p "$(dirname "$tap_cask")"
      run cp "$CASK" "$tap_cask"
    fi
    if [ -z "$(git -C "$TAP_DIR" status --porcelain -- "$tap_cask")" ]; then
      say "tap has nothing to commit"
    else
      run git -C "$TAP_DIR" add "$tap_cask"
      run git -C "$TAP_DIR" commit -m "warmline $VERSION"
    fi
    # Pushing an already-pushed branch is a no-op, which keeps re-runs safe.
    run git -C "$TAP_DIR" push origin HEAD
  fi
fi

# --- the part that stays manual ----------------------------------------------

say "== done -- manual checklist (deliberately not automated)"
cat <<EOF

  1. Lint the cask. The audit needs the tap tapped first, or it reports
     "Cask 'warmline' is unavailable":
       brew tap miguel-barroso/warmline    # if not already tapped
       brew style Miguel-Barroso/warmline
       brew audit --cask --strict --online Miguel-Barroso/warmline/warmline

  2. Test-drive the cask, knowing that a real brew install/uninstall pair
     ALWAYS touches the real ~/.claude -- Homebrew scrubs CLAUDE_CONFIG_DIR
     from the postflight environment. Snapshot settings.json first:
       cp ~/.claude/settings.json /tmp/settings.json.pre-brew
       brew install --cask miguel-barroso/warmline/warmline
       brew uninstall --cask warmline

  3. Publish the GitHub release page for $TAG (gh release create $TAG, or the
     web UI). Its install one-liner pins the tag twice -- once for the script,
     once for the files the script fetches:
       curl -fsSL https://raw.githubusercontent.com/$OWNER_REPO/$TAG/install.sh | bash -s -- --ref $TAG
EOF

if [ "$DRY_RUN" = 1 ] && [ "$PREFLIGHT_OK" = 0 ]; then
  say "dry run: NOTE -- a real run would have refused at preflight (see above)"
fi
