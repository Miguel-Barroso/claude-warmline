# Packaging

warmline is three scripts and a markdown file. There is nothing to compile, so
a package's whole job is to put `warmline` and `warmline-audit` on `PATH` and
`statusline.py` + `keep-warm.md` somewhere the command can find them.

Layout a package should produce:

```
<prefix>/bin/warmline
<prefix>/bin/warmline-audit
<prefix>/share/warmline/statusline.py
<prefix>/share/warmline/keep-warm.md
```

`warmline setup` resolves that layout by following symlinks from the command
back to its real location and looking beside it, then in `../share/warmline`.
`WARMLINE_SHARE_DIR` overrides it for anything unusual. A package that simply
unpacks the repo — everything in one directory — works too, because "beside the
command" is checked first.

## The awkward part: who wires Claude Code

Installing warmline means two things: commands on `PATH`, and a `statusLine`
entry in `~/.claude/settings.json` pointing at a copy of `statusline.py`. Only
the first is a package manager's job. Making the user do the second by hand is a
bad trade — it is one more command to remember, and one more to *re-*remember
after every upgrade, or the statusline silently stays on the old version.

So `warmline setup` exists as a command any packaging format can call, and each
format should call it if it can do so honestly — at install time, and again on
upgrade. It is safe to automate because it refuses to replace a `statusLine`
that isn't warmline's without `--force`, backs up `settings.json` every time, and
`warmline setup --remove` undoes exactly what it did.

## Homebrew

[`homebrew/warmline.rb`](homebrew/warmline.rb) is the cask, and this file is its
source of truth. It ships from a tap —
[`Miguel-Barroso/homebrew-warmline`](https://github.com/Miguel-Barroso/homebrew-warmline)
— not from homebrew-core, which requires a level of notability this project
doesn't have yet and would slow every release down to core's review cadence.
Users get one command, which installs *and* wires:

```sh
brew install Miguel-Barroso/warmline/warmline
```

The tap is a second repository, and nothing but the cask connects the two: the
`homebrew-` prefix in its name is what lets `brew install
Miguel-Barroso/warmline/warmline` find it without a separate `brew tap`, and the
`url` inside the cask points at a source tarball GitHub generates from a tag
here. No submodule, no fork, no artifact to upload.

### Why a cask and not a formula

warmline is a CLI tool, so a formula is the obvious choice — and it was one, for
a day. A formula cannot finish the job. Its `post_install` hook runs under a
sandbox whose rules include `deny_read_home` ([`Library/Homebrew/sandbox.rb`,
`add_install_hook_rules`](https://github.com/Homebrew/brew/blob/main/Library/Homebrew/sandbox.rb)),
so a formula cannot so much as read `~/.claude`, let alone wire it. Verified, not
assumed: a probe formula whose `post_install` wrote to the real home produced

```
Warning: The post-install step did not complete successfully
```

and no file. That leaves formula users typing `warmline setup` after every
install and every upgrade, which is exactly the failure mode above.

Cask flight blocks are not sandboxed. `postflight` runs `warmline setup` and
`uninstall_preflight` runs `warmline setup --remove` — *pre*flight, because it
has to happen while the command still exists. On upgrade both fire in turn, so
the statusline is unwired and rewired at the new version rather than left stale.

The cost is real and worth stating: **casks are macOS-only**. Homebrew on Linux
has no cask support, so `brew install` there fails with a clear message and the
[curl/wget installer](../install.sh) is the path — which is a one-command install
on Linux anyway, doing both halves itself. Trading a two-step brew install on
Linux for a one-step brew install on macOS costs nothing that the installer
doesn't already cover.

### Per release

Copy the cask over and change two lines — the tag in `url` and the `sha256`:

```sh
VERSION=2.2.1
curl -fsSL "https://github.com/Miguel-Barroso/claude-warmline/archive/refs/tags/v$VERSION.tar.gz" \
  | shasum -a 256
```

A tag cannot contain the checksum of its own tarball, so the copy in this repo
carries a placeholder until the tag is pushed, then gets the real value in a
follow-up commit. The tap always carries the pinned copy.

Before pushing the tap, run the checks Homebrew runs:

```sh
brew style Miguel-Barroso/warmline
brew audit --cask --strict --online Miguel-Barroso/warmline/warmline
brew install Miguel-Barroso/warmline/warmline    # wires your real ~/.claude
brew uninstall Miguel-Barroso/warmline/warmline  # and unwires it
```

There is no `brew test` for a cask, so the install/uninstall pair *is* the test —
and unlike a formula's sandboxed test, it touches your real config, because that
is the thing being tested. `warmline status` before and after tells you whether
it did the right thing.

The cask declares no dependencies. warmline needs `python3` at runtime and both
commands say so plainly when it is missing; pulling a 60 MB python in to run
three standard-library scripts on a machine that already has python3 would be a
worse trade than the error message.

## Anything else

A distro package or a manual prefix install follows the same layout. Call
`warmline setup` from a post-install hook if the format has one that can write to
the invoking user's home; if it can't — the usual case for system-wide packages,
which install as root for every user — leave it out and say so in the package
description, because a wiring step the user doesn't know about is worse than one
they do. The curl/wget installer ([`install.sh`](../install.sh)) stays the
primary path and does both halves itself, because it is the one that can't rely
on a package manager being there at all.
