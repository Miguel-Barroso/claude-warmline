# Packaging

warmline is three scripts and a markdown file. There is nothing to compile, so
a package's whole job is to put `warmline` and `warmline-audit` on `PATH` and
`statusline.py` + `keep-warm.md` in `share/warmline`. **The Claude Code side is
never a package's business** — no formula, no `.deb`, no installer of anyone
else's should edit `~/.claude/settings.json`. That step is
[`warmline setup`](../docs/INSTALL.md#from-a-package-manager), which the user
runs once after installing and again after upgrading.

Layout a package should produce:

```
<prefix>/bin/warmline
<prefix>/bin/warmline-audit
<prefix>/share/warmline/statusline.py
<prefix>/share/warmline/keep-warm.md
```

`warmline setup` resolves that layout by following symlinks from the command
back to its real location and looking beside it, then in `../share/warmline`.
`WARMLINE_SHARE_DIR` overrides it for anything unusual.

## Homebrew

[`homebrew/warmline.rb`](homebrew/warmline.rb) is the formula, and this file is
its source of truth. It ships from a tap —
[`Miguel-Barroso/homebrew-warmline`](https://github.com/Miguel-Barroso/homebrew-warmline)
— not from homebrew-core, which requires a level of notability this project
doesn't have yet and would slow every release down to core's review cadence.
Users get:

```sh
brew install Miguel-Barroso/warmline/warmline
warmline setup
```

The tap is a second repository, and nothing but the formula connects the two:
the `homebrew-` prefix in its name is what lets `brew install
Miguel-Barroso/warmline/warmline` find it without a separate `brew tap`, and the
`url` inside the formula points at a source tarball GitHub generates from a tag
here. No submodule, no fork, no artifact to upload.

Per release, copy the formula over and change two lines — the tag in `url` and
the `sha256`:

```sh
VERSION=2.2.0
curl -fsSL "https://github.com/Miguel-Barroso/claude-warmline/archive/refs/tags/v$VERSION.tar.gz" \
  | shasum -a 256
```

Before pushing, run the checks Homebrew runs:

```sh
brew style   Miguel-Barroso/warmline
brew audit   --strict --online Miguel-Barroso/warmline/warmline
brew install --build-from-source Miguel-Barroso/warmline/warmline
brew test    Miguel-Barroso/warmline/warmline
```

`brew test` sets `CLAUDE_CONFIG_DIR` to a scratch directory and runs the real
`warmline setup` in it, so it proves the prefix layout resolves and the
statusline renders — without touching the tester's own Claude Code config.

The formula declares no dependencies. warmline needs `python3` at runtime and
both commands say so plainly when it is missing; pulling a 60 MB python keg in
to run three standard-library scripts on a machine that already has python3
would be a worse trade than the error message.

## Anything else

A distro package or a manual prefix install follows the same layout and the same
`warmline setup` step; nothing in either command assumes Homebrew. The curl/wget
installer ([`install.sh`](../install.sh)) stays the primary path and does both
halves itself, because it is the one that can't rely on a package manager being
there at all.
