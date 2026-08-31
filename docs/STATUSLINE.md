# The statusline

[← back to the README](../README.md)

One line, rendered by Claude Code every time it repaints — and, since v1.6.0,
re-rendered every 60 seconds while the session just sits there:

```
Fable 5 | claude-warmline | ctx 43% (168k) | cache HOT (cold ~13:04) | gap 12m | keep-warm on
```

## Fields

| Field | Meaning |
|---|---|
| `ctx 43% (168k)` | context-window utilization and input tokens in the conversation |
| `cache HOT (cold ~13:04)` | the previous request read from the prompt cache; the cache expires at the wall-clock time shown (green) |
| `cache HOT (cold in 9m)` | still warm, but within 15 minutes of the TTL — act now or pay the rebuild (yellow) |
| `cache COLD(rebuilt)` | the previous request found the prefix cold and re-cached it (yellow) |
| `cache COLD(ttl?)` | *inferred*: the session has been quiet longer than the TTL, so the cache has expired regardless of the (stale) usage fields (red) |
| `cache ?` | usage fields unavailable (dim) |
| `gap 12m` | minutes since this session's last API turn — shown from 5m; idle repaints don't reset it |
| `keep-warm on` | the keep-warm policy is installed and current (green); `on*` yellow, `off` dim, `?` yellow |

`ctx` turns yellow past 80% (`WARMLINE_CTX_WARN_PCT`), because
[auto-compaction](KEEP-WARM.md#auto-compact-the-one-you-dont-choose) — measured
firing around 84% of the window — rewrites the prefix without being asked and
takes the cache with it. It is the only warning you get, and the only thing
worth doing about it (compact deliberately, or don't start a wait you can't
keep) has to happen before the threshold, not after.

The model name and directory come straight from Claude Code's own payload.
The TTL behind the countdown is auto-detected from the transcript's own
cache-write records (each write is tagged `ephemeral_5m` or `ephemeral_1h`),
so short-TTL setups need no configuration; `WARMLINE_TTL_MIN` still forces it.

## Staying current while idle

Claude Code re-runs a statusline command on conversation events only — a
session that finishes its work and goes quiet would never repaint, and the
last-painted line would freeze on screen. That is how a session that went
cold at noon can still show a green `cache HOT` at 8 pm.

warmline closes that hole twice over:

1. **The installer sets `statusLine.refreshInterval: 60`** in
   `settings.json`, which tells Claude Code to re-run the statusline every
   60 seconds *in addition to* the event-driven repaints. The countdown
   ticks while you idle, and `COLD(ttl?)` takes over within a minute of the
   TTL actually passing. This refresh runs the local script only — it never
   talks to the API, costs nothing, and (to be explicit) does **not** keep
   the cache warm; it keeps the *gauge* honest. Tune it with
   `WARMLINE_REFRESH_SEC=<seconds>` at install time, or disable with
   `WARMLINE_REFRESH_SEC=0`; a hand-edited value in `settings.json`
   survives reinstalls.
2. **The HOT verdict carries its absolute expiry time** (`cold ~13:04`,
   computed as last-turn time + TTL). On Claude Code versions that predate
   `refreshInterval` (which ignore the key and stay event-driven), and for
   a line frozen while the machine slept, even a stale repaint tells you
   exactly when warmth ended.

`warmline status` reports which mode you're in on its `refresh` row.

## The keep-warm field

It answers one question — *is the prevention half armed?* — from the same
source of truth as [`warmline keep-warm status`](KEEP-WARM.md): the marker
block in `$CLAUDE_CONFIG_DIR/CLAUDE.md` (default `~/.claude/CLAUDE.md`),
re-read on every render, never a cached state file. Turn it on or off and
the line follows on the next repaint.

| Shown | State |
|---|---|
| `keep-warm on` | both markers present, and the block matches the installed policy |
| `keep-warm on*` | installed, but the block differs from `~/.claude/warmline-keep-warm.md` — an older release's wording, or a hand edit. Refresh with `warmline keep-warm off && warmline keep-warm on` |
| `keep-warm off` | no block (or no CLAUDE.md) |
| `keep-warm ?` | one marker without its pair: a malformed block, which the agent may read as truncated policy. Same fix |

`on` means *installed*, not *pinging*. Keep-warm is an instruction the agent
follows during long waits, not a daemon — the field tells you the instruction
is in place; [`warmline-audit`](AUDIT.md) tells you whether it worked.

The star matters because the block in CLAUDE.md is what the agent reads, and
upgrading warmline used to refresh only the policy *source* beside it. A
session could follow a superseded policy indefinitely while the line painted
a confident green `on`. `on*` is the same comparison
[`warmline keep-warm status`](KEEP-WARM.md#status-is-read-never-remembered)
reports as `policy modified` — one extra small read and a whitespace-insensitive
compare, measured at 0.15 ms, skipped entirely when the block isn't there.

Set `WARMLINE_NO_KEEPWARM=1` to drop the field if you never use keep-warm.

## Colors

On by default — Claude Code renders ANSI in the statusline. Green is good,
yellow is "act now", red is "already cold", dim is informational. Set
`NO_COLOR` or `WARMLINE_NO_COLOR` to turn them off.

## How the gap is measured

Each session gets a stamp file in `~/.claude/warmline-state/`
(`WARMLINE_STATE_DIR`) holding the last usage snapshot Claude Code passed in.
The file is rewritten — moving its mtime — **only when that snapshot changes**,
i.e. when a real API turn happened. So:

- repainting an idle session doesn't reset the clock; the gap keeps growing
  and `COLD(ttl?)` stays on screen instead of flickering back to a stale `HOT`;
- concurrent sessions don't reset each other's clock, because the stamp is
  keyed by `session_id`;
- a *fresh* turn (a changed snapshot against a stored one) is authoritative
  over the TTL inference — first sighting of a session is not treated as
  fresh, so a resumed session still infers `COLD(ttl?)` from its transcript
  mtime rather than claiming warmth it can't know about.

Stamps older than 7 days are pruned on render.

## Honest limitations

- **The usage fields lag one turn.** Claude Code hands the statusline the
  numbers of the *previous* request, so `HOT` and `COLD(rebuilt)` describe
  what already happened, not what your next message will find.
- **`COLD(ttl?)` is an inference**, not a measurement — hence the `?`. It says
  "quiet for longer than the TTL", and the TTL is a documented product
  behavior, not something the statusline can observe.
- **The line is pull-based, with a timer.** The script runs when Claude Code
  repaints — on conversation events and, with `refreshInterval` wired, every
  60 seconds. No timer fires while the machine sleeps, so a lid-closed laptop
  wakes to one stale line; the next tick (within a minute) corrects it, and
  the absolute `cold ~13:04` in the HOT verdict is truthful even before that.
- **Prefix drift is invisible until it bills.** An edited CLAUDE.md, changed
  git state or a different set of MCP servers can invalidate the prefix with
  no idle time at all; you see it on the next turn as `COLD(rebuilt)`.

## Configuration

| Environment variable | Default | Effect on the line |
|---|---|---|
| `WARMLINE_TTL_MIN` | auto | cache TTL in minutes — drives `COLD(ttl?)` and the countdown. Unset, it is auto-detected from the transcript's cache-bucket records (60m fallback) |
| `WARMLINE_REFRESH_SEC` | `60` | install-time: the `refreshInterval` written to `settings.json`; `0` writes none |
| `WARMLINE_STATE_DIR` | `~/.claude/warmline-state` | stamp files |
| `WARMLINE_NO_KEEPWARM` | unset | if set, omit the keep-warm field |
| `WARMLINE_CTX_WARN_PCT` | `80` | context-window percentage at which `ctx` turns yellow (auto-compact warning); `0` or less disables |
| `WARMLINE_NO_COLOR` / `NO_COLOR` | unset | plain output, no ANSI |
| `WARMLINE_DEBUG` | unset | keep the last raw payload at `$WARMLINE_STATE_DIR/last-payload.json` |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | config dir; its `CLAUDE.md` holds the keep-warm block |

Set them in the environment Claude Code starts from, or in the `env` block of
`~/.claude/settings.json`.

## When the line doesn't appear

1. **Give it a few seconds**, then restart the session — Claude Code picks up
   `statusLine` changes on its own, but not always instantly.
2. **Check it's wired:** `warmline status` shows `statusline ON` and the path.
3. **Run it by hand:** `echo '{}' | ~/.claude/warmline-statusline.py` should
   print a line, not a traceback. `claude --debug` logs the exit code and
   stderr of the first statusline invocation of a session.
4. **You're not in a terminal.** The desktop app and the IDE extensions don't
   render custom statuslines at all — see [where warmline works](SURFACES.md).
5. **Managed settings can disable it.** If your organization sets
   `disableAllHooks` or `allowManagedHooksOnly`, Claude Code runs only a
   statusline that comes from managed settings, and yours silently vanishes.
