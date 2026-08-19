# The statusline

[← back to the README](../README.md)

One line, rendered by Claude Code every time it repaints:

```
Fable 5 | claude-warmline | ctx 43% (168k) | cache HOT | gap 12m | keep-warm on
```

## Fields

| Field | Meaning |
|---|---|
| `ctx 43% (168k)` | context-window utilization and input tokens in the conversation |
| `cache HOT` | the previous request read from the prompt cache (green) |
| `cache HOT (cold in 9m)` | still warm, but the idle gap is within 15 minutes of the TTL — act now or pay the rebuild (yellow) |
| `cache COLD(rebuilt)` | the previous request found the prefix cold and re-cached it (yellow) |
| `cache COLD(ttl?)` | *inferred*: the session has been quiet longer than the TTL, so the cache has expired regardless of the (stale) usage fields (red) |
| `cache ?` | usage fields unavailable (dim) |
| `gap 12m` | minutes since this session's last API turn — shown from 5m; idle repaints don't reset it |
| `keep-warm on` | the keep-warm policy is installed (green); `off` is dim, `?` yellow |

The model name and directory come straight from Claude Code's own payload.

## The keep-warm field

It answers one question — *is the prevention half armed?* — from the same
source of truth as [`warmline keep-warm status`](KEEP-WARM.md): the marker
block in `$CLAUDE_CONFIG_DIR/CLAUDE.md` (default `~/.claude/CLAUDE.md`),
re-read on every render, never a cached state file. Turn it on or off and
the line follows on the next repaint.

| Shown | State |
|---|---|
| `keep-warm on` | both markers present — the policy is in your CLAUDE.md |
| `keep-warm off` | no block (or no CLAUDE.md) |
| `keep-warm ?` | one marker without its pair: a malformed block, which the agent may read as truncated policy. Fix with `warmline keep-warm off && warmline keep-warm on` |

`on` means *installed*, not *pinging*. Keep-warm is an instruction the agent
follows during long waits, not a daemon — the field tells you the instruction
is in place; [`warmline-audit`](AUDIT.md) tells you whether it worked.

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
- **The line is pull-based.** The script runs only when Claude Code repaints,
  so while your machine sleeps the last rendered line — often a by-then-false
  `HOT` — stays frozen on screen. What warmline guarantees is that the idle
  clock survives repaints: the first repaint after you return already reads
  `COLD(ttl?)`, before you've spent anything.
- **Prefix drift is invisible until it bills.** An edited CLAUDE.md, changed
  git state or a different set of MCP servers can invalidate the prefix with
  no idle time at all; you see it on the next turn as `COLD(rebuilt)`.

## Configuration

| Environment variable | Default | Effect on the line |
|---|---|---|
| `WARMLINE_TTL_MIN` | `60` | cache TTL in minutes — drives `COLD(ttl?)` and the countdown |
| `WARMLINE_STATE_DIR` | `~/.claude/warmline-state` | stamp files |
| `WARMLINE_NO_KEEPWARM` | unset | if set, omit the keep-warm field |
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
