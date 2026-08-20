# Installing, updating, configuring

[← back to the README](../README.md)

```sh
curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash
```

or from a checkout:

```sh
git clone https://github.com/Miguel-Barroso/claude-warmline.git
cd claude-warmline
./install.sh
```

Requires `python3` (standard library only) and `bash`. Nothing else, and
nothing phones home.

## What lands where

| File | Destination |
|---|---|
| `statusline.py` | `~/.claude/warmline-statusline.py`, wired into `~/.claude/settings.json` |
| `warmline` | `~/.local/bin/warmline` |
| `warmline-audit` | `~/.local/bin/warmline-audit` |
| `keep-warm.md` | `~/.claude/warmline-keep-warm.md` (the policy source) |

`settings.json` is backed up to `settings.json.warmline-bak` on every run, and
an existing custom `statusLine` is never replaced without `--force`. The wiring
includes `"refreshInterval": 60`, so the gauge re-renders every minute even
while a session idles — [why that matters](STATUSLINE.md#staying-current-while-idle).
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
  ttl         auto -- from each transcript's cache buckets (60m fallback)
  refresh     every 60s while idle -- the gauge can't go stale
```

## Updating

The installer is the updater. Re-run the same `curl | bash` one-liner (or
`./install.sh` from a pulled checkout) — it recognizes its own statusline and
replaces it, the `warmline` command, and the auditor in place without
`--force`; your `settings.json` is backed up on every run, and your keep-warm
on/off choice is left as it was. [CHANGELOG.md](../CHANGELOG.md) tracks tagged
releases.

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
| `WARMLINE_TTL_MIN` | auto | prompt-cache TTL in minutes; unset, both the statusline and the auditor detect it from each transcript's cache-bucket records (60m fallback) |
| `WARMLINE_REFRESH_SEC` | `60` | install-time: the statusline `refreshInterval` the installer writes; `0` omits it (a value you hand-edit later survives reinstalls) |
| `WARMLINE_STATE_DIR` | `~/.claude/warmline-state` | stamp/state directory |
| `WARMLINE_BIN_DIR` | `~/.local/bin` | where the installer puts the `warmline` and `warmline-audit` commands |
| `WARMLINE_NO_KEEPWARM` | unset | if set, the statusline omits the keep-warm field |
| `WARMLINE_NO_COLOR` | unset | if set (or `NO_COLOR`), plain output without ANSI colors |
| `WARMLINE_FORCE_COLOR` | unset | if set, colored audit output even when piped |
| `WARMLINE_DEBUG` | unset | if set, keeps the last raw statusline payload for inspection |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Claude Code's config dir — warmline follows it for settings, CLAUDE.md and transcripts |

Set these in the environment Claude Code starts from, or in the `env` block of
`~/.claude/settings.json`. `WARMLINE_TTL_MIN` is honored by both the statusline
and `warmline-audit`.

## Compatibility

Verified against Claude Code **2.1.233**. The statusline's JSON fields were
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
synthetic transcript against `warmline-audit` including the `--price` estimate,
every cold-cause attribution, per-session TTL auto-detection, a now-relative
corpus against `--live`, config-dir discovery, and TTY vs piped formatting; a
synthetic multi-project corpus against `--all`; the installer's
`refreshInterval` wiring (default, hand-tuned, disabled); and the `warmline`
CLI's keep-warm state transitions (on→on, off→off, malformed blocks reported
truthfully instead of a false ON), with unrelated CLAUDE.md content verified to
survive every operation and a clean-install check that the `warmline` command
actually lands. The same suite runs in CI on every push.
