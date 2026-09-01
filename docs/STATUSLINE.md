# The statusline

[← back to the README](../README.md)

One line, rendered by Claude Code every time it repaints:

```
Fable 5 | claude-warmline | ctx 43% (168k) | cache HOT (cold ~13:04)
```

Since v2.1.251 Claude Code puts the prompt cache's real state on the
statusline's stdin — whether the prefix is warm, which TTL it is on, and the
epoch second it expires. **warmline shows those numbers and does not compute
its own.** It reads no transcript, keeps no state file, and does not time the
gap between turns to guess whether the cache survived. Claude Code owns the
truth; this line owns the presentation.

## Fields

| Field | Meaning |
|---|---|
| `ctx 43% (168k)` | context-window utilization and input tokens in the conversation |
| `cache HOT (cold ~13:04)` | the cached prefix is warm and leaves its TTL at the wall-clock time shown (green) |
| `cache HOT (cold ~13:04)` | *within 15 minutes of that time* — identical text, yellow |
| `cache HOT 5m (cold ~13:04)` | as above, on the 5-minute TTL (see [the TTL badge](#the-ttl-badge)) |
| `cache HOT` | warm, but this response carried no expiry timestamp |
| `cache COLD` | the prefix is outside its TTL; the next turn re-caches it (red) |
| `cache off` | `caching_observed` is false — prompt caching is off, or this provider or gateway never reports cache tokens (dim) |
| `cache ?` | no `prompt_cache` object: Claude Code before v2.1.251, or before the session's first API response (dim) |
| `keep-warm on*` / `?` | shown **only** when the policy needs attention (see [keep-warm](#the-keep-warm-field)) |

`COLD`, `off` and `?` are three different facts and are deliberately not
collapsed into one. *"The cache expired"* means wait or ping; *"caching isn't
happening"* means nothing here will ever warm up; *"warmline can't see"* means
don't trust the field at all. Guessing between them is how a cache gauge
starts lying, and a confidently wrong verdict is worse than an honest `?`.

`ctx` turns yellow past 80% (`WARMLINE_CTX_WARN_PCT`), because
[auto-compaction](KEEP-WARM.md#auto-compact-the-one-you-dont-choose) — measured
firing around 84% of the window — rewrites the prefix without being asked and
takes the cache with it. It is the only warning you get, and the only thing
worth doing about it (compact deliberately, or don't start a wait you can't
keep) has to happen before the threshold, not after.

The model name and directory come straight from Claude Code's own payload.

## Why a clock and not a countdown

The expiry is always absolute wall-clock time, never `37m` ticking down.

A frozen countdown is *wrong*; a frozen clock is still *true*. Claude Code
repaints the statusline on conversation events, so a session that finishes its
work and goes quiet may not repaint for a long while — and the long-quiet
session is exactly the one whose cache is in danger. A line that last painted
`cold ~13:04` is honest at any hour you happen to glance at it. A line that
last painted `37m` is a lie that gets worse the longer you look away.

It also costs nothing to keep correct: the text doesn't change as the deadline
approaches, only its colour, so no field shifts width and no digit ticks in
your peripheral vision all day.

## The TTL badge

`5m` appears next to the verdict only on the 5-minute TTL. The 1-hour bucket
is the norm for a subscription's main conversation and goes unlabelled, because
a field that reads the same thing for three months stops being read.

The short bucket is worth a badge because it silently invalidates the mental
model built on the long one — it is what you get on usage credits, an API key,
or a cloud provider, and it breaks
[keep-warm](KEEP-WARM.md) outright: a policy pinging every ~50 minutes is
refreshing a cache that died 45 minutes earlier.

### The warning window, exactly

`HOT` turns yellow for **the final 15 minutes, capped at half the TTL**:

| TTL | yellow for | share of the cache's life |
|---|---|---|
| `1h` | the last **15 minutes** | 25% |
| `5m` | the last **2.5 minutes** | 50% |
| anything else, or no `ttl` | the last **15 minutes** | uncapped |

The cap is the whole point of the rule. A flat 15 minutes is longer than a
5-minute cache ever lives, so without it the short bucket would be painted
yellow from birth — a warning that is always on is not a warning. Half a TTL
is deliberately generous rather than proportional (25% of five minutes would be
75 seconds): the line only repaints on a timer tick, so the window has to be
wide enough to contain more than one, or the warning can be missed entirely.
An unrecognised `ttl` string is left uncapped rather than guessed at, since
assuming a short TTL would paint most of a long one yellow.

## Staying current while idle

The installer still sets `statusLine.refreshInterval: 60` in `settings.json`,
which re-runs the script every 60 seconds in addition to the event-driven
repaints. This runs the local script only — it never talks to the API, costs
nothing, and (to be explicit) does **not** keep the cache warm; it keeps the
*gauge* honest. Tune it with `WARMLINE_REFRESH_SEC=<seconds>` at install time,
or disable it with `WARMLINE_REFRESH_SEC=0`; a hand-edited value in
`settings.json` survives reinstalls. `warmline status` reports which mode
you're in on its `refresh` row.

Claude Code also re-runs a statusline command when the warm prompt cache in the
data that script last received reaches its `expires_at`. **That trigger is
real, and warmline has observed it firing on 2.1.252**: a session that received
`expires_at` at 12:27:15 and then sat completely silent — no user message, no
assistant message, `refreshInterval` parked at an hour — had its statusline
re-run at 12:27:16 with `warm: false`, repainting green `HOT` to red `COLD`
without anyone touching the keyboard. Refreshing before expiry replaces that
trigger rather than stacking on it: an expiry pushed from 12:36:07 out to
12:38:37 fired once, at 12:38:37, and never at the superseded time.

So the trigger, not the timer, is what makes `COLD` correct. **The timer earns
its keep somewhere else: it is the only thing that turns the line yellow.** The
trigger is a single shot at expiry, so nothing is scheduled for the moment the
warning window opens 15 minutes earlier — and an idle session generates no
other events by definition. In the same run above, the line went straight from
green to red: between the two repaints the script was not invoked once, and the
yellow warning never rendered. Idle is precisely when a "you have 15 minutes
left" warning is worth having, so the polling stays for that, not for `COLD`.

One consequence worth stating plainly: with `WARMLINE_REFRESH_SEC=0` the gauge
is still *correct* — it flips to `COLD` at the right second — it just stops
warning you first.

Two things then make a missed repaint survivable: the absolute expiry time is
truthful on a frozen line, and a `warm: true` whose `expires_at` has already
passed is rendered `COLD` rather than believed. That second rule is load-bearing
for a reason the docs don't spell out — at expiry Claude Code flips `warm` to
`false` but leaves `expires_at` at its old value rather than nulling it, so
warmth is read from `warm` and the clock is only ever used for the label.

No timer fires while the machine sleeps, so a lid-closed laptop wakes to one
stale line; the next repaint corrects it, and the printed expiry time was never
untrue.

## The keep-warm field

It appears **only when something needs doing about it**. A correctly installed
policy renders nothing, and so does a deliberate absence — `warmline keep-warm
status` is where you ask whether it's on. A field that has read a green `on` for
three months is wallpaper, and sitting next to a red `cache COLD` it reads as a
contradiction.

| Shown | State |
|---|---|
| `keep-warm on*` | installed, but the block differs from `~/.claude/warmline-keep-warm.md` — an older release's wording, or a hand edit. Refresh with `warmline keep-warm off && warmline keep-warm on` |
| `keep-warm ?` | one marker without its pair: a malformed block, which the agent may read as truncated policy. Same fix |

Both come from the same source of truth as
[`warmline keep-warm status`](KEEP-WARM.md): the marker block in
`$CLAUDE_CONFIG_DIR/CLAUDE.md` (default `~/.claude/CLAUDE.md`), re-read on
every render, never a cached state file.

The star matters because the block in CLAUDE.md is what the agent reads, and
upgrading warmline used to refresh only the policy *source* beside it. A
session could follow a superseded policy indefinitely while the line painted
a confident green `on`. `on*` is the same comparison
[`warmline keep-warm status`](KEEP-WARM.md#status-is-read-never-remembered)
reports as `policy modified` — one extra small read and a whitespace-insensitive
compare, measured at 0.15 ms, skipped entirely when the block isn't there.

`on` means *installed*, not *pinging*. Keep-warm is an instruction the agent
follows during long waits, not a daemon; [`warmline audit`](AUDIT.md) tells you
whether it worked.

Set `WARMLINE_NO_KEEPWARM=1` to drop the field entirely.

## Colors

On by default — Claude Code renders ANSI in the statusline. Green is good,
yellow is "act now", red is "already cold", dim is informational. Set
`NO_COLOR` or `WARMLINE_NO_COLOR` to turn them off.

## Honest limitations

- **The cache fields describe the last API response.** Claude Code computes
  them from the cache token counts it has already seen, so they tell you what
  the prefix is doing now, not what an edit you just made will do to it.
- **Subagents are not counted.** `prompt_cache` covers the main conversation
  only. A subagent runs against its own cache on its own TTL, and neither
  refreshes the other.
- **Prefix drift is invisible until it bills.** Changing the effort level,
  turning on fast mode, denying a whole tool, toggling a plugin or upgrading
  Claude Code all invalidate the prefix with no idle time at all; you see it on
  the next turn as `COLD`, with no warning before.
- **The line is pull-based.** The script runs when Claude Code repaints. See
  [staying current while idle](#staying-current-while-idle).

## Configuration

| Environment variable | Default | Effect on the line |
|---|---|---|
| `WARMLINE_REFRESH_SEC` | `60` | install-time: the `refreshInterval` written to `settings.json`; `0` writes none |
| `WARMLINE_NO_KEEPWARM` | unset | if set, never show the keep-warm field |
| `WARMLINE_CTX_WARN_PCT` | `80` | context-window percentage at which `ctx` turns yellow (auto-compact warning); `0` or less disables |
| `WARMLINE_NO_COLOR` / `NO_COLOR` | unset | plain output, no ANSI |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | config dir; its `CLAUDE.md` holds the keep-warm block |

Set them in the environment Claude Code starts from, or in the `env` block of
`~/.claude/settings.json`.

`WARMLINE_TTL_MIN` no longer affects the statusline — the TTL now comes from
Claude Code. It still applies to [`warmline audit`](AUDIT.md), which grades
historical turns where no such field was ever recorded.

## When the line doesn't appear

1. **Give it a few seconds**, then restart the session — Claude Code picks up
   `statusLine` changes on its own, but not always instantly.
2. **Check it's wired:** `warmline status` shows `statusline ON` and the path.
3. **Run it by hand:** `echo '{}' | ~/.claude/warmline-statusline.py` should
   print a line, not a traceback. `claude --debug` logs the exit code and
   stderr of the first statusline invocation of a session.
4. **`cache ?` that never changes:** check `claude --version`. The cache fields
   need v2.1.251 or later; before that warmline has nothing authoritative to
   read and says so rather than guessing.
5. **You're not in a terminal.** The desktop app and the IDE extensions don't
   render custom statuslines at all — see [where warmline works](SURFACES.md).
6. **Managed settings can disable it.** If your organization sets
   `disableAllHooks` or `allowManagedHooksOnly`, Claude Code runs only a
   statusline that comes from managed settings, and yours silently vanishes.
