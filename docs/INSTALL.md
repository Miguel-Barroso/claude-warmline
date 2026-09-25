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
| `afk.md` | `~/.claude/warmline-afk.md` (the [AFK mode](AFK.md) procedure source, inert until `warmline afk enable`) |

The installer never enables AFK mode, since that takes your own consent. Once
you have, `warmline afk enable` adds `~/.claude/commands/afk.md`, a
`UserPromptSubmit` hook and a `Bash(… afk:*)` permission rule to
`settings.json`, and `~/.claude/warmline-afk/`.

Both commands are installed, and the auditor has two spellings: `warmline audit
…` is the primary form the docs use, and it runs `warmline-audit`, which remains
fully supported — it is what scripts should keep calling, what a checkout runs
(`./warmline-audit`), and the only form available on a
[manual Windows install without Git Bash](#native-windows), where the bash
`warmline` wrapper isn't.

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
`WARMLINE_BIN_DIR` (commands).

## PATH

A command in a directory your shell doesn't search is a half-install, so if
`~/.local/bin` isn't on your `PATH`, the installer offers to fix it:

```
note: /home/you/.local/bin is not on your PATH, so 'warmline' won't resolve yet.
add it to /home/you/.bashrc? [Y/n]
```

Yes appends one marked block — the `export PATH="$HOME/.local/bin:$PATH"` line
between two `claude-warmline PATH` comments — to the file your shell really
reads: `~/.zshrc` for zsh, `~/.bashrc` for bash on Linux, `~/.bash_profile` for
bash on macOS, where terminals open login shells. Any other shell gets the line
printed rather than an edit this project can't test. `warmline uninstall` takes
the block back out, and a second install recognizes its own line instead of
adding another.

It asks at most once, and often not at all:

- **Debian and Ubuntu** already ship a `~/.profile` that adds `~/.local/bin`
  *if the directory exists* — which it didn't when your shell started and does
  by the time the installer finishes. Appending our own line there would be a
  duplicate that outlives the install, so the installer names the file that
  already handles it and stops. Open a new terminal and `warmline` is there.
- **With no terminal to ask on** — `curl | bash` inside a script, a CI job, a
  Dockerfile — it prints the line instead of waiting for an answer that can't
  come. Nothing blocks, ever.
- `--path` adds it without asking and `--no-path` neither asks nor edits, for
  automation where a question would be a hang.

The question goes to `/dev/tty` rather than standard input, because under
`curl | bash` standard input *is* the installer: reading an answer from there
would swallow the rest of the install.

## Installer flags

| Flag | Effect |
|---|---|
| `--keep-warm` | install-time shorthand for [`warmline keep-warm on`](KEEP-WARM.md) |
| `--force` | replace an existing non-warmline statusline |
| `--ref TAG` | install that tag or branch instead of main's tip ([above](#installing-a-specific-release)) |
| `--path` | put the bin dir on your `PATH` without asking ([above](#path)) |
| `--no-path` | never offer to; print the line to add and edit nothing |
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

If you've enabled [AFK mode](AFK.md), an update also re-renders `/afk` and its
hook against the new install, so a moved command never leaves a hook pointing
at nothing. An update never turns AFK mode on.

## Uninstalling

```sh
warmline uninstall          # or, from a checkout: ./install.sh --uninstall
```

Removes the statusline and its wiring, both commands, the policy file, the
state directory, the `PATH` line if you let the installer add one, the
keep-warm block from your CLAUDE.md — leaving the rest of that file untouched —
and, if you enabled it, AFK mode: `/afk`, its hook and permission rule, and the
recorded consent. Your own hooks and permission rules stay.
The two forms do the same work; `warmline uninstall` just doesn't need the
installer to still be lying around, which after a `curl | bash` it isn't.

Two copies it will not delete, and says so rather than skipping quietly: one a
package manager installed (under Homebrew, `brew uninstall warmline` is the
command that does it — deleting the files behind brew's back would leave brew
believing warmline is still there), and a checkout's own `./warmline`, which is
source rather than an install. A checkout can still uninstall the copy in
`~/.local/bin`: that is what `./warmline uninstall` does.

## Configuration

| Environment variable | Default | Meaning |
|---|---|---|
| `WARMLINE_TTL_MIN` | auto | prompt-cache TTL in minutes, for **`warmline-audit`** only; unset, it detects the TTL from each transcript's cache-bucket records (60m fallback) |
| `WARMLINE_REFRESH_SEC` | `60` | install-time: the statusline `refreshInterval` the installer writes; `0` omits it (a value you hand-edit later survives reinstalls) |
| `WARMLINE_BIN_DIR` | `~/.local/bin` | where the installer puts the `warmline` and `warmline-audit` commands |
| `WARMLINE_REF` | `main` | the tag or branch the installer fetches files from — same as `--ref`; also pins the `warmline` command's last-resort download of the policy text |
| `WARMLINE_NO_KEEPWARM` | unset | if set, the statusline never shows the keep-warm field |
| `WARMLINE_NO_QUOTA` | unset | if set, the statusline never shows the plan-limit field (`5h 78%`) |
| `WARMLINE_NO_AFK` | unset | if set, the statusline never shows the AFK field |
| `WARMLINE_AFK_NO_INHIBIT` | unset | if set, `warmline afk wait` doesn't hold off system sleep |
| `WARMLINE_SHARE_DIR` | unset | where `warmline setup` looks for `statusline.py`, `keep-warm.md` and `afk.md`; unset, beside the command then `../share/warmline` |
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

Claude Code runs on Windows two ways, and warmline supports both. They are
separate installs that share nothing: each has its own `~/.claude`, its own
transcripts, its own `CLAUDE.md` and its own copy of warmline.

| | Native Windows | WSL |
|---|---|---|
| Claude Code config | `%USERPROFILE%\.claude` | `~/.claude` inside the distro |
| install from | Git Bash | the distro's shell |
| status line command | `py -3 "C:/Users/you/.claude/warmline-statusline.py"` | `~/.claude/warmline-statusline.py` |
| `warmline awake` / AFK | PowerShell sleep holder | PowerShell sleep holder (the Windows host) |

### Native Windows

Needs [Git for Windows](https://git-scm.com/download/win) (Claude Code for
Windows uses its bash too) and Python 3.7+ from python.org or the Microsoft
Store. From a Git Bash window, the one-liner above works unchanged:

```sh
curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash
```

What the installer does differently there:

- **Python discovery.** It tries `py -3`, then `python`, then `python3`, and
  runs each one rather than trusting `command -v` -- a fresh Windows answers
  `python3` with the Microsoft Store's "install me" stub, which exists on
  `PATH` and runs nothing. No working candidate, no install.
- **The status line command names its interpreter.** Claude Code for Windows
  runs `statusLine` through Git Bash, and through PowerShell when Git Bash
  isn't there. A bare `.py` path works in neither: PowerShell hands it to the
  file association, which opens it and prints nothing, so the status line
  stays blank. The installer writes
  `py -3 "C:/Users/you/.claude/warmline-statusline.py"` instead -- forward
  slashes, because Git Bash eats backslashes, and a `C:/` path that bash,
  PowerShell and Windows Python all read the same way.
- **`PATH`.** Claude Code's own Windows installer puts
  `%USERPROFILE%\.local\bin` on your user `PATH`, and that is where
  `warmline` lands, so Git Bash usually finds it with no edit. If it doesn't,
  the offer writes `~/.bashrc`; Git Bash starts login shells, and Git for
  Windows creates a `~/.bash_profile` that sources `~/.bashrc` the first time
  it sees one without the other.

`warmline` and `warmline-audit` are scripts without an extension: run them
from Git Bash. The status line itself doesn't care which shell you use.

Windows Python reads and writes files and pipes as cp1252 unless told
otherwise, and dies on the first byte cp1252 has no letter for -- a `CLAUDE.md`
with Japanese in it, say. The statusline and the auditor read and write UTF-8
explicitly, and every Python step inside the bash scripts runs with
`PYTHONUTF8=1`.

**Without Git Bash**, install by hand: copy `statusline.py` to
`%USERPROFILE%\.claude\warmline-statusline.py`, and in
`%USERPROFILE%\.claude\settings.json` set

```json
"statusLine": {"type": "command", "command": "py -3 \"C:/Users/you/.claude/warmline-statusline.py\"", "refreshInterval": 60}
```

Name the interpreter and use forward slashes, for the reasons above. Run the
auditor as `py -3 warmline-audit [args]`, and toggle keep-warm by adding or
removing the marker-delimited block ([`keep-warm.md`](../keep-warm.md)) in
`%USERPROFILE%\.claude\CLAUDE.md`. `warmline awake` and AFK mode need Git Bash.

### WSL

Inside the distro, WSL is Linux: the installer, the one-liner and everything
else behave exactly as on Linux. Two differences are Windows' doing:

- **Sleep.** It's the Windows host that sleeps, not the Linux VM, and WSL's
  `systemd-inhibit` can't reach it (unprivileged, it is refused outright). So
  `warmline awake` and the AFK waiter use the same PowerShell holder native
  Windows does, through `powershell.exe` on WSL's interop `PATH`.
- **Line endings.** Clone inside the distro. Git for Windows defaults to
  `core.autocrlf=true`, and before this repo's `.gitattributes` pinned LF, a
  clone made by Windows' git (on `/mnt/c`, say) failed in WSL on the first
  line: `/usr/bin/env: 'bash\r': No such file or directory`.

The two sides can read each other's history. From WSL, audit your native
Windows sessions with

```sh
CLAUDE_CONFIG_DIR=/mnt/c/Users/you/.claude warmline audit --all
```

### Keeping Windows awake

`warmline awake` and the AFK waiter hold the machine up with
`SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)` -- the call
`caffeinate -is` makes on macOS -- from a small PowerShell process that holds
it until its stdin closes. warmline keeps that pipe open for exactly as long as
the wrapped command runs. When the command exits, or warmline is killed
outright, the pipe closes, PowerShell exits, and Windows drops the request.
No admin rights, nothing left behind. It keeps the system awake, not the
display, and it doesn't stop a lid close or the power button.

`powercfg /requests`, from an elevated prompt, is Windows' own list of who is
holding the machine awake.

### What's tested

The whole suite runs under Git Bash with Windows Python: locally on Windows 11
(Python 3.14) and in CI on `windows-latest` on every push. It includes a
round-trip of the installed status line command through both `bash -c` and
`powershell.exe -Command`, and UTF-8 checks for the statusline and the
auditor. Under WSL it runs as it does on Linux. The PowerShell holder was
checked on a real machine from both Git Bash and WSL by reading the system
execution state, but the suite exercises it against a stub.

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
guarantee, held by construction); the `PATH` offer against a fake `HOME` — the
marked block written once and not twice, a stock Debian `~/.profile` recognized
rather than duplicated, `--no-path` editing nothing — and `warmline uninstall`
removing every piece while refusing to delete a checkout's files or a package
manager's copy; and `warmline setup` against a synthetic
prefix (`bin/` + `share/warmline`, reached through a symlink), covering the
force/refusal contract, `--remove`, and a missing source tree. Pricing is
hermetic: the suite ships a synthetic `.claude.json` whose arithmetic solves to
round rates, so no test reads your real cost data. Windows gets its own
section: the statusline and the auditor on a `CLAUDE.md` that cp1252 can't
decode, `warmline awake` under WSL against a stub `powershell.exe` (the
`SetThreadExecutionState` call, the exit code, the holder released even when
the wrapped command leaves a background job behind), and, under Git Bash, the
installed status line command run through both `bash -c` and
`powershell.exe -Command`. The same suite runs in CI on every push, on Ubuntu
and, under Git Bash, on Windows.
