# claude-warmline

A cache-aware statusline for [Claude Code](https://code.claude.com), plus an optional
keep-the-cache-warm policy for long background waits.

```
Fable 5 | my-project | ctx 43% (168k) | cache HOT | gap 12m
```

At a glance: which model you're on, where you are, how full the context window is,
whether the **prompt cache** is still hot, and how long the session has been quiet.

## Why

If you orchestrate long-running work from Claude Code — CI pipelines, builds,
background agents — a session routinely goes quiet for 30–90 minutes. The provider's
prompt cache expires after a TTL (~1 hour on subscription plans), so the session wakes
up **cold**: the next request re-reads the entire context uncached and pays the cache
re-write premium (~2× input) at exactly the moment a wave of results arrives.

Claude Code doesn't surface any of this. warmline makes it visible, and the optional
keep-warm policy avoids it entirely: a scheduled wakeup just before the TTL expires
refreshes the cache for the price of one cache *read* (~0.1× input) instead of a full
re-*write*.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash
```

or from a checkout:

```sh
git clone https://github.com/Miguel-Barroso/claude-warmline.git
cd claude-warmline
./install.sh
```

The installer copies `statusline.py` to `~/.claude/warmline-statusline.py` and wires it
into `~/.claude/settings.json` (your previous `settings.json` is backed up first; an
existing custom statusline is never replaced without `--force`). Claude Code usually
picks it up within seconds — restart the session if it doesn't.

| Flag | Effect |
|---|---|
| `--keep-warm` | also append the keep-warm policy block to `~/.claude/CLAUDE.md` |
| `--force` | replace an existing non-warmline statusline |
| `--uninstall` | remove the script, the settings entry, state files, and the policy block |

Requires `python3` (standard library only) and `bash`.

## Reading the line

| Field | Meaning |
|---|---|
| `ctx 43% (168k)` | context-window utilization and input tokens in the conversation |
| `cache HOT` | the previous request read from the prompt cache |
| `cache COLD(rebuilt)` | the previous request found the prefix cold and re-cached it |
| `cache COLD(ttl?)` | *inferred*: the session has been quiet longer than the TTL, so the cache has expired regardless of the (stale) usage fields |
| `cache ?` | usage fields unavailable |
| `gap 12m` | minutes since this session's previous statusline render (shown from 5m) |

Honest limitation: Claude Code hands the statusline the usage numbers of the
*previous* request, so `HOT`/`COLD(rebuilt)` lag one turn, and `COLD(ttl?)` is a
time-based inference — hence the `?`. Gaps are tracked per session (stamp files in
`~/.claude/warmline-state/`), so concurrent Claude Code sessions on one machine don't
reset each other's idle clock.

The practical use: when you come back to a session showing a big `ctx` and
`COLD(ttl?)`, the cache is gone anyway — that's the cheapest possible moment to run
`/compact <what to keep>` before feeding it new work.

## The keep-warm policy

`--keep-warm` appends a short, marker-delimited block to your global `~/.claude/CLAUDE.md`
(see [`keep-warm.md`](keep-warm.md)) instructing the agent: when it launches background
work expected to exceed ~45 minutes while context is substantial, schedule a wakeup
~50 minutes out; on wake, reschedule if the work is still running, otherwise continue —
and never let wakeups outlive the wait. Results then always land against a hot cache.

This relies on the agent having a wakeup/scheduling tool (`ScheduleWakeup`) in its
Claude Code build; on builds without it the block is simply inert. Each ping costs
roughly 0.1× your context in cache-read quota — the policy deliberately skips small
contexts, where going cold is cheap.

## Configuration

| Environment variable | Default | Meaning |
|---|---|---|
| `WARMLINE_TTL_MIN` | `60` | prompt-cache TTL in minutes (set `5` for short-TTL setups) |
| `WARMLINE_STATE_DIR` | `~/.claude/warmline-state` | stamp/state directory |
| `WARMLINE_DEBUG` | unset | if set, keeps the last raw statusline payload for inspection |

Set these in the environment Claude Code starts from, or in the `env` block of
`~/.claude/settings.json`.

## Tests

```sh
./test.sh
```

Replays representative statusline payloads (hot, cold-rebuild, TTL-expired, sparse,
garbage, concurrent-session isolation) against the script.

## License

[MIT](LICENSE)
