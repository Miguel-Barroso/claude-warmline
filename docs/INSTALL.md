# Installing, updating, configuring

[← back to the README](../README.md)

```sh
curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash
```

or, on a machine with `wget` and no `curl` (the installer uses whichever it
finds, for its own downloads too):

```sh
wget -qO- https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash
```

or with Homebrew on macOS, from this project's tap:

```sh
brew install Miguel-Barroso/warmline/warmline
```

or from a checkout:

```sh
git clone https://github.com/Miguel-Barroso/claude-warmline.git
cd claude-warmline
./install.sh
```

Requires `python3` (standard library only) and `bash`. Nothing else, and
nothing phones home. Every one of these is a single command that leaves you with
a working statusline — including Homebrew, which is a cask rather than a formula
precisely so that it can be ([why](#from-a-package-manager)).

## Installing a specific release

The one-liner above installs main's tip. To install a tagged release, name the
tag twice — once for the script, once for the files it fetches:

```sh
curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/v2.1.0/install.sh | bash -s -- --ref v2.1.0
```

Both halves matter, and this is why: the installer downloads `statusline.py`,
`warmline`, `warmline-audit` and `keep-warm.md` itself, so the tag in the URL
only pins the installer. `--ref` (or `WARMLINE_REF=v2.1.0`) pins everything it
goes on to fetch. Without it a tagged URL installs the tagged installer and
main's tip of everything else — which is fine on the day the tag *is* the tip,
and quietly wrong every day after. **Every release page links its own tag**, so
the version you clicked is the version you get.

A pinned install always goes to the network, even from a checkout: the tree you
happen to be standing in is not the tag you asked for. From a checkout, the
equivalent is `git checkout v2.1.0 && ./install.sh` — which needs no network at
all. Releases before v2.1.0 predate the flag; pin those with the checkout form.

## From a package manager

A package manager puts commands on your `PATH`. Installing warmline also means
putting a `statusLine` entry in `~/.claude/settings.json` — and if that is left
to you, it is a step to remember at install time and to *re*member after every
upgrade, or your statusline quietly stays on the old version. So it isn't left to
you:

```sh
brew install   Miguel-Barroso/warmline/warmline   # installs and wires, one command
brew upgrade   warmline                           # re-wires at the new version
brew uninstall warmline                           # unwires, then removes
```

The first command taps `Miguel-Barroso/homebrew-warmline` on its own; you never
run `brew tap`. **macOS only** — Homebrew on Linux has no cask support, so use
the installer there, which is also one command.

That "cask" is the whole reason this works. A Homebrew *formula* — the normal
choice for a CLI tool, and what this was for a day — runs its `post_install` hook
in a sandbox that denies reading `$HOME` at all, so it cannot wire anything and
you would be back to typing a second command after every install and upgrade. A
cask's flight blocks aren't sandboxed. [`packaging/README.md`](../packaging/README.md)
has the evidence and the release checklist;
[`packaging/homebrew/warmline.rb`](../packaging/homebrew/warmline.rb) is the
cask's source of truth, copied into the tap on each release.

Nothing is done behind your back. The wiring is the same `warmline setup` you can
run yourself, and it is what any other packaging format should call:

```sh
warmline setup            # installs the statusline, wires settings.json
warmline setup --force    # replace a statusLine that isn't warmline's
warmline setup --remove   # unwire it and take back the files it installed
```

`setup` is exactly the wiring half of `install.sh`: same backup of
`settings.json`, same refusal to replace a foreign statusline without `--force`,
same `refreshInterval`, same keep-warm block refresh — and it prints every file
it touches. It finds `statusline.py` and `keep-warm.md` beside the command or in
`../share/warmline`, following symlinks (which is how a Homebrew `bin` symlink
into the Caskroom resolves); `WARMLINE_SHARE_DIR` overrides. `warmline status`
confirms the result at any time.

One thing an uninstall deliberately leaves alone: if you turned keep-warm on, the
block in your `CLAUDE.md` stays, and the console says so. Removing text from a
file you also write in is not something an uninstaller should decide —
`warmline keep-warm off` does it when you want it.

## What lands where

| File | Destination |
|---|---|
| `statusline.py` | `~/.claude/warmline-statusline.py`, wired into `~/.claude/settings.json` |
| `warmline` | `~/.local/bin/warmline` |
| `warmline-audit` | `~/.local/bin/warmline-audit` |
| `keep-warm.md` | `~/.claude/warmline-keep-warm.md` (the policy source) |

Both commands are installed, and the auditor has two spellings: `warmline audit
…` is the primary form the docs use, and it runs `warmline-audit`, which remains
fully supported — it is what scripts should keep calling, what a checkout runs
(`./warmline-audit`), and the only form available on
[manual/Windows installs](#windows), where the bash `warmline` wrapper isn't.

`settings.json` is backed up to `settings.json.warmline-bak` on every run, and
an existing custom `statusLine` is never replaced without `--force`. The wiring
includes `"refreshInterval": 60`, so the gauge re-renders every minute even
while a session idles. Claude Code flips `HOT` to `COLD` on its own at the
exact expiry second, so this timer is not what makes the verdict correct — it
is what turns the line yellow *before* the deadline, which nothing else does
during an idle session
([why](STATUSLINE.md#staying-current-while-idle)).
Claude Code usually picks the statusline up within seconds — restart the
session if it doesn't.

Override the destinations with `CLAUDE_CONFIG_DIR` (config dir) and
`WARMLINE_BIN_DIR` (commands). If `~/.local/bin` isn't on your `PATH`, the
installer says so and prints the exact line to add
(`export PATH="$HOME/.local/bin:$PATH"`) — it never edits your shell startup
files itself.

## Installer flags

| Flag | Effect |
|---|---|
| `--keep-warm` | install-time shorthand for [`warmline keep-warm on`](KEEP-WARM.md) |
| `--force` | replace an existing non-warmline statusline |
| `--ref TAG` | install that tag or branch instead of main's tip ([above](#installing-a-specific-release)) |
| `--uninstall` | remove everything the installer added, including the policy block |
| `--help` | usage |

To pass flags through the `curl` form:
`curl -fsSL …/install.sh | bash -s -- --keep-warm`.

**The installer installs warmline. The `warmline` command controls it.** At any
time, one command answers "what is warmline doing on this machine?":

```
$ warmline status
claude-warmline status  (config: /Users/mb/.claude)
  statusline  ON   /Users/mb/.claude/warmline-statusline.py
  keep-warm   OFF  (enable: warmline keep-warm on)
  auditor     ON   /Users/mb/.local/bin/warmline-audit
  ttl         auto -- warmline-audit reads it per transcript (60m fallback); the statusline uses Claude Code's own
  refresh     every 60s while idle -- the gauge can't go stale
```

## Updating

The installer is the updater. Re-run the same `curl | bash` one-liner (or
`./install.sh` from a pulled checkout) — it recognizes its own statusline and
replaces it, the `warmline` command, and the auditor in place without
`--force`; your `settings.json` is backed up on every run, and your keep-warm
on/off choice is left as it was. [CHANGELOG.md](../CHANGELOG.md) tracks tagged
releases, and a `--ref` install moves you to exactly the one you name — forward
or back.

Since v1.8.0 an update also refreshes the keep-warm block **inside your
CLAUDE.md**, not just the policy file beside it — otherwise your agent keeps
following the release you first installed. It only rewrites a block that still
matches the policy it replaced; a block you edited yourself is left alone, with
a note on the console telling you the wording moved on. Either way the rest of
your CLAUDE.md is untouched. See
[editing the policy](KEEP-WARM.md#editing-the-policy).

## Uninstalling

```sh
./install.sh --uninstall
```

Removes the statusline and its wiring, both commands, the policy file, the
state directory, and the keep-warm block from your CLAUDE.md — leaving the rest
of that file untouched.

## Configuration

| Environment variable | Default | Meaning |
|---|---|---|
| `WARMLINE_TTL_MIN` | auto | prompt-cache TTL in minutes, for **`warmline-audit`** only; unset, it detects the TTL from each transcript's cache-bucket records (60m fallback) |
| `WARMLINE_REFRESH_SEC` | `60` | install-time: the statusline `refreshInterval` the installer writes; `0` omits it (a value you hand-edit later survives reinstalls) |
| `WARMLINE_BIN_DIR` | `~/.local/bin` | where the installer puts the `warmline` and `warmline-audit` commands |
| `WARMLINE_REF` | `main` | the tag or branch the installer fetches files from — same as `--ref`; also pins the `warmline` command's last-resort download of the policy text |
| `WARMLINE_NO_KEEPWARM` | unset | if set, the statusline never shows the keep-warm field |
| `WARMLINE_NO_QUOTA` | unset | if set, the statusline never shows the plan-limit field (`5h 78%`) |
| `WARMLINE_SHARE_DIR` | unset | where `warmline setup` looks for `statusline.py` and `keep-warm.md`; unset, beside the command then `../share/warmline` |
| `WARMLINE_CTX_WARN_PCT` | unset (auto) | percentage at which the statusline's `ctx` field turns yellow; unset, it warns within 10k of where auto-compact actually fires (`window - 33000`) and stays silent when auto-compact is off; `0` disables |
| `WARMLINE_NO_COLOR` | unset | if set (or `NO_COLOR`), plain output without ANSI colors |
| `WARMLINE_FORCE_COLOR` | unset | if set, colored audit output even when piped |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Claude Code's config dir — warmline follows it for settings, CLAUDE.md and transcripts |

Set these in the environment Claude Code starts from, or in the `env` block of
`~/.claude/settings.json`.

`WARMLINE_TTL_MIN` no longer affects the statusline, which reads the TTL from
Claude Code's own `prompt_cache` data. It still applies to `warmline-audit`,
which grades historical turns where no such field was ever recorded — that
split is the whole design: **live truth comes from Claude Code, history comes
from warmline.** `WARMLINE_STATE_DIR` and `WARMLINE_DEBUG` are gone with the
stamp files the statusline no longer keeps.

## Compatibility

Verified against Claude Code **2.1.252**. The statusline's JSON fields were
checked against real harness payloads, and `warmline-audit` parses every
transcript format present on the reference machine — Claude Code versions
**2.1.181 through 2.1.233**, 145 sessions, zero malformed entries. One known
format quirk is handled: some versions omit `requestId` on ~28% of assistant
entries, so the audit dedupes API requests by `message.id`. Claude Code
versions without `statusLine.refreshInterval` support ignore the key
harmlessly — the gauge is then event-driven only, which the absolute expiry
time in the HOT verdict is designed to survive.

Which front ends each piece reaches — terminal, desktop app, IDE, SSH, cloud —
is [its own page](SURFACES.md).

## Windows

The statusline and the auditor are pure standard-library Python; only the
installer and the test suite are bash. Manual install:

1. copy `statusline.py` to `%USERPROFILE%\.claude\warmline-statusline.py`
   (and, optionally, `warmline-audit` anywhere convenient)
2. in `%USERPROFILE%\.claude\settings.json`, set
   `"statusLine": {"type": "command", "command": "python C:\\Users\\you\\.claude\\warmline-statusline.py"}`
3. run the auditor as `python warmline-audit [args]`

The `warmline` command is bash too, so on Windows toggle keep-warm by hand —
add or remove the marker-delimited block (the text is
[`keep-warm.md`](../keep-warm.md)) in `%USERPROFILE%\.claude\CLAUDE.md` — or use
WSL / Git Bash. ANSI colors render fine in Windows Terminal. A tested
`install.ps1` would be a welcome contribution — in keeping with this project's
philosophy, we don't ship one we can't test.

## Tests

```sh
./test.sh
```

Replays representative statusline payloads (hot, cold-rebuild, TTL-expired,
sparse, garbage, concurrent-session isolation, idle repaints not resetting the
clock, a fresh turn overriding the TTL inference, the expiry countdown, the
absolute expiry time, TTL auto-detection from cache buckets, the keep-warm
field in all three states plus its opt-out, ANSI colors) against the script; a
synthetic transcript against `warmline-audit` including the `--price` estimate
(split input/output pricing, the bare-flag defaults, output tokens counted and
priced separately), every cold-cause attribution, the percentage shares on
verdicts, causes and the `--all` table, per-session TTL auto-detection, a
now-relative corpus against `--live`, config-dir discovery, and TTY vs piped
formatting; a synthetic multi-project corpus against `--all`; the installer's
`refreshInterval` wiring (default, hand-tuned, disabled) and its `--ref` pinning
(a malformed ref refused before anything is touched, a pinned ref fetching
rather than copying the checkout it was run from, a failed fetch leaving the
installed copy intact); the `warmline` CLI's
keep-warm state transitions (on→on, off→off, malformed blocks reported
truthfully instead of a false ON), with unrelated CLAUDE.md content verified to
survive every operation and a clean-install check that the `warmline` command
actually lands; `warmline awake` against a stub inhibitor — the exact
`caffeinate -is` invocation, the default `claude` command, and the wrapped
command's exit propagating straight through (the no-sleep cleanup-on-`/exit`
guarantee, held by construction); and `warmline setup` against a synthetic
prefix (`bin/` + `share/warmline`, reached through a symlink), covering the
force/refusal contract, `--remove`, and a missing source tree. Pricing is
hermetic: the suite ships a synthetic `.claude.json` whose arithmetic solves to
round rates, so no test reads your real cost data. The same suite runs in CI on
every push.
