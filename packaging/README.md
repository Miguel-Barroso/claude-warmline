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
a day. A formula cannot finish the job. Its post-install hook runs under a
sandbox whose rules include `deny_read_home` ([`Library/Homebrew/sandbox.rb`,
`add_install_hook_rules`](https://github.com/Homebrew/brew/blob/main/Library/Homebrew/sandbox.rb)),
so a formula cannot so much as read `~/.claude`, let alone wire it. Verified, not
assumed: a probe formula whose `post_install` wrote to the real home produced

```
Warning: The post-install step did not complete successfully
```

and no file. Homebrew 7's declarative `post_install_steps` doesn't change that —
[`formula_installer.rb`](https://github.com/Homebrew/brew/blob/main/Library/Homebrew/formula_installer.rb)
builds the post-install sandbox without consulting the steps, so a formula has
nowhere to declare an exception even if it wants one. That leaves formula users
typing `warmline setup` after every install and every upgrade, which is exactly
the failure mode above.

Casks get the exception. `postflight_steps` runs `warmline setup` and
`uninstall_preflight_steps` runs `warmline setup --remove` — *pre*flight, because
it has to happen while the command still exists. On upgrade both fire in turn, so
the statusline is unwired and rewired at the new version rather than left stale.

Those steps are sandboxed too — the legacy `postflight` blocks weren't, and are
deprecated as of Homebrew 7 — but a `run` step may name the paths it needs:

```ruby
writable_paths: [".claude"], writable_base: :home
```

and [`cask/artifact/install_steps.rb`](https://github.com/Homebrew/brew/blob/main/Library/Homebrew/cask/artifact/install_steps.rb)
grants both read and write there. One directory, declared in the cask, auditable
by anyone reading it — which is a better bargain than the unsandboxed block it
replaces.

### Why the cask calls `brew-setup` and not `warmline setup`

The sandbox points `$HOME` at a throwaway directory, deliberately, so that a
command cannot go wandering through the real home. It grants the declared path
without telling the command where that path is, so `warmline setup` would compute
`$HOME/.claude`, wire a `settings.json` in a directory deleted seconds later, and
report success. Silently doing nothing is the worst of the available outcomes.

[`homebrew/brew-setup`](homebrew/brew-setup) is the answer, and all of it:
resolve the account's home from the password database (`getpwuid`, which the
sandbox does allow), export it as `CLAUDE_CONFIG_DIR`, `exec warmline setup`.
Outside a sandbox it returns the same answer `$HOME` would, so it is also just a
slower way of running `warmline setup` by hand.

The cost is real and worth stating: **casks are macOS-only**. Homebrew on Linux
has no cask support, so `brew install` there fails with a clear message and the
[curl/wget installer](../install.sh) is the path — which is a one-command install
on Linux anyway, doing both halves itself. Trading a two-step brew install on
Linux for a one-step brew install on macOS costs nothing that the installer
doesn't already cover.

### Getting into an official tap

The cask is written to Homebrew's rules so that it *could* be submitted, but the
honest position is that neither official repository would take it today, for two
separate reasons.

**`homebrew/cask` doesn't want it.**
[Acceptable Casks](https://docs.brew.sh/Acceptable-Casks#appropriate-package-type)
is explicit: casks distribute pre-built files published by the upstream
developer, and "open-source command-line-only software normally belongs in
`homebrew/core` as a formula built from source". warmline is open-source, CLI
only, and ships as a source tarball. Being unsuitable for core does not make it
suitable for cask — that document says so in the next sentence.

**`homebrew/core` would take the package type, but not this package.** Not yet:
[the acceptance
policy](https://docs.brew.sh/Package-Acceptance-Policy#notability) asks for 30
forks, 30 watchers or 75 stars — 90/90/225 when the author submits their own
project — and a repository at least 30 days old. And a core formula still could
not wire the statusline, per the section above, so core acceptance would trade a
one-command install for a two-command one.

So the tap is not a waiting room; it is the right home for now. What would change
the picture, in order: the notability thresholds, and a way for a formula to
declare a writable path in its post-install sandbox the way a cask already can.
The second is an upstream feature request, not something this repository can fix,
and it is worth filing before any submission — the cask exists only because that
gap does.

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
and it touches your real config, because that is the thing being tested.
`warmline status` before and after tells you whether it did the right thing.
Snapshot `~/.claude/settings.json` first; `./install.sh` from the checkout puts
everything back.

Do not skip it because `style` and `audit` were green. Both read the cask; only
the install runs it, and everything that can go wrong here — a sandbox denial, a
`$HOME` that isn't yours, a path that resolves inside the staged tarball instead
of your home — goes wrong silently, with an exit status of 0 and a cheerful 🍺.

A tap is not trusted by default ([since Homebrew
6.0.0](https://docs.brew.sh/Tap-Trust)), but installing by fully qualified name —
which is the only form this README ever gives out — trusts that one cask and
proceeds. Nothing extra to run, and nothing extra to tell users.

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

`warmline uninstall` is safe to ship alongside any of this. It unwires
everything and removes what the installer installed, but a command it finds
under `/usr`, `/opt`, a Cellar or a Caskroom is reported and left alone —
deleting a package's files behind its back would leave the package manager
believing warmline is still installed, which is a worse state than an extra
command to run.
