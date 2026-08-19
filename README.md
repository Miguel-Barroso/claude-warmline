# claude-warmline

[![tests](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml/badge.svg)](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml)
[![version](https://img.shields.io/github/v/tag/Miguel-Barroso/claude-warmline?label=version)](https://github.com/Miguel-Barroso/claude-warmline/tags)
[![license](https://img.shields.io/github/license/Miguel-Barroso/claude-warmline)](LICENSE)

**Know when your Claude Code session is about to wake up slow and expensive — and prevent it.**

Claude Code re-sends your entire conversation with every message. A server-side
*prompt cache* makes that ~10× cheaper — until it silently expires after about an
hour of quiet, and your next turn pays double price to rebuild it. claude-warmline
is three small tools against that, no dependencies beyond `python3` and `bash`:

- **a statusline** showing the cache state live (`HOT`/`COLD`), next to model, context usage, and idle time
- **a keep-warm policy** that has the agent cheaply ping the session through long waits, so results land against a hot cache
- **an auditor** that grades any past session turn-by-turn: what stayed warm, what went cold, what it cost

![The warmline statusline in its three states: cache HOT in green, cache COLD(rebuilt) in yellow, cache COLD(ttl?) in red](docs/statusline.svg)

## New to this? The 60-second background

Claude doesn't remember anything between requests. Every time you send a message,
Claude Code re-sends the *entire* conversation so far — system prompt, tools, every
file that was read, every reply. On a long session that's easily 100k+ tokens of
input per turn, and you'd pay for all of it every time.

The **prompt cache** is what makes this affordable: the provider keeps your
conversation prefix cached server-side, so the next request *reads* it at roughly
**0.1×** the normal input price instead of reprocessing it. Writing the cache in the
first place costs about **2×** — a premium you pay once, then amortize over every
subsequent turn. This is why a busy session feels fast and cheap even at 200k context.

The catch: the cache **expires after a TTL — about 1 hour of inactivity**. Come back
to a big session after lunch and the next request silently reprocesses everything
uncached and pays the 2× re-write premium again — at exactly the moment you wanted
results. The cache also dies *without* any idle time whenever the conversation prefix
changes: `/compact` rewrites the whole context, so it always triggers a full re-cache.

Claude Code doesn't surface any of this. warmline makes it visible.

## Reading the line

| Field | Meaning |
|---|---|
| `ctx 43% (168k)` | context-window utilization and input tokens in the conversation |
| `cache HOT` | the previous request read from the prompt cache (green) |
| `cache HOT (cold in 9m)` | still warm, but the idle gap is within 15 minutes of the TTL — act now or pay the rebuild (yellow) |
| `cache COLD(rebuilt)` | the previous request found the prefix cold and re-cached it (yellow) |
| `cache COLD(ttl?)` | *inferred*: the session has been quiet longer than the TTL, so the cache has expired regardless of the (stale) usage fields (red) |
| `cache ?` | usage fields unavailable |
| `gap 12m` | minutes since this session's last API turn (shown from 5m; idle repaints don't reset it) |

Colors are on by default (Claude Code renders ANSI in the statusline); set
`NO_COLOR` or `WARMLINE_NO_COLOR` to disable them.

Honest limitations: Claude Code hands the statusline the usage numbers of the
*previous* request, so `HOT`/`COLD(rebuilt)` lag one turn, and `COLD(ttl?)` is a
time-based inference — hence the `?`. The line is also pull-based: the script only
runs when Claude Code repaints it, so while your machine sleeps the last rendered
line — often a by-then-false `HOT` — stays frozen on screen. What warmline
guarantees is that the idle clock survives repaints: only a real API turn resets
it, so the first repaint after you return already reads `COLD(ttl?)` — before
you've spent anything — and it stays that way until a request actually lands.
Gaps are tracked per session (stamp files in `~/.claude/warmline-state/`), so
concurrent Claude Code sessions on one machine don't reset each other's idle clock.

The practical use: `COLD(ttl?)` on a big `ctx` marks the cheapest possible moment
to change course — which way to jump is the next section.

## Coming back cold: `/compact`, `/clear`, or neither?

A `COLD(ttl?)` on a big context is a fork in the road. The cache is gone; whatever
you do next, that context gets processed once more at the expensive uncached rate.
The only question is what that one unavoidable expensive pass buys you:

- **You still need the conversation history → `/compact`.** Compaction must read
  the whole conversation once to summarize it. On a warm cache that read would be
  cheap — but it would also destroy a cache you already paid 2× to build, which is
  why compacting while `HOT` is the worst-timed move (unless you're out of context
  window and have no choice). On a cold cache the expensive pass was going to
  happen on your very next message anyway — compaction just redirects it into
  producing a small summary, so from then on you cache and carry a few thousand
  tokens instead of 100k+. That's why `/compact` has the most benefit exactly when
  the cache is already dead.
- **Your state is written down outside the conversation → `/clear`.** If what you
  need to continue lives in memory files, a plan document, or the code and git
  history themselves, `/clear` skips even the summarization pass — nothing ever
  pays to read the old context again. And a fresh session does *not* slurp
  everything back in: its prefix is just the system prompt, your CLAUDE.md, and
  the one-line memory index — individual memory files and project files are only
  read when they become relevant. That targeted re-reading costs fresh input
  tokens, but it's almost always far less than one summarization pass over a
  100k+ conversation.
- **Small context → do nothing.** Going cold on 20k tokens is cheap to rebuild.
  Both the gauge and the keep-warm policy exist for the 100k+ case.

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

## What we measured (not modeled)

All of the claims above are checkable against real transcripts — Claude Code records
`cache_read_input_tokens` and `cache_creation_input_tokens` for every API turn in the
session's `.jsonl` file, and [`warmline-audit`](#auditing-past-sessions) grades them.
From a real 13-hour orchestration session (2026-08-18, ~300k context, merge-queue
babysitting with background CI watchers):

- **260 API turns: 255 HOT, 1 COLD(rebuilt), 1 COLD(ttl)** — 45.9M tokens read from
  cache; only 99k tokens ever re-cached cold.
- Background task notifications arriving every ~9 minutes kept the cache hot for four
  straight hours at **~400 tokens of cache-write per wake** (reads meanwhile grew from
  150k to 317k). **If background work is in flight, its notifications keep the cache
  warm for free** — no policy needed.
- The one `COLD(ttl)` came after a 6-hour overnight silence — the machine was asleep,
  so nothing could have fired. **No scheduled wakeup survives a closed lid** (on macOS,
  `caffeinate` is the workaround for planned long waits).
- The one `COLD(rebuilt)` followed `/compact`: a full 58k-token re-cache within
  minutes of activity. Prefix invalidation and TTL expiry are different failure modes,
  which is exactly why the statusline distinguishes them.
- Headless probes confirm the TTL bucket: Claude Code writes the cache with
  `ephemeral_1h` (the 1-hour TTL), and a resumed session reads its full prefix back
  (33,614 tokens read, 56 written, in the reference probe).
- The TTL boundary itself, measured in a clean-room two-arm run (isolated headless
  sessions, no MCP servers, frozen environment): after **50 minutes** of total
  silence, a probe read its full 71,312-token prefix from cache and wrote only 56
  tokens; after **70 minutes**, an identical session found its cache gone and
  re-wrote all 45,033 tokens of its content. Warm at 50, cold at 70 — the 1-hour
  TTL is real, and the keep-warm ping interval (~50 minutes) sits safely inside it.
- The cold arm also demonstrated *why* pinging works: **reads refresh the TTL**.
  Its probe still found the shared system block warm, because the other arm had
  read that block 20 minutes earlier. A keep-warm ping is exactly that refresh,
  applied to your whole prefix.
- An earlier, deliberately-dirty run of the same experiment surfaced a subtler
  failure mode: a headless `--resume` regenerates
  the whole system prompt, so git-status drift, MCP server availability, or an edited
  CLAUDE.md between turns silently diverges the prefix — and everything past the
  divergence re-caches at full price. **Prefix stability matters as much as TTL**:
  no keep-warm ping can help a session whose prefix churns between turns.

## The keep-warm policy

`--keep-warm` appends a short, marker-delimited block to your global `~/.claude/CLAUDE.md`
(see [`keep-warm.md`](keep-warm.md)) instructing the agent: when it launches background
work expected to exceed ~45 minutes while context is substantial, schedule a wakeup
~50 minutes out; on wake, reschedule if the work is still running, otherwise continue —
and never let wakeups outlive the wait. Results then always land against a hot cache.

When it actually matters — and when it doesn't:

- **Redundant while background tasks are running.** Their completion notifications
  already wake the session well inside the TTL (measured above). The policy tells the
  agent to skip scheduling in that case.
- **Valuable when the session goes genuinely quiet** — waiting on remote CI with no
  local watcher, or a human stepping away with 100k+ of warm context they intend to
  come back to. Each ping costs ~0.1× your context in cache-read quota vs ~2× for the
  cold re-write, so keep-warm pays for itself for idle stretches up to roughly
  10–12 hours *if* you return. The policy deliberately skips small contexts, where
  going cold is cheap.
- **Defeated by host sleep.** Wakeups can't fire on a sleeping machine. For a planned
  long wait on macOS: `caffeinate -is` (or plug in and keep the lid open).

Tool availability varies by Claude Code build: `ScheduleWakeup` may be absent, or
present but runtime-gated (rejected outside a dynamic `/loop` session). On such builds
the block is inert or the agent falls back to a scheduled recurring prompt —
`/loop 50m <ping>` achieves the same wake cadence via cron.

## Auditing past sessions

```sh
./warmline-audit                      # latest session of the current project
./warmline-audit path/to/session.jsonl
./warmline-audit --ttl 5 --json       # short-TTL setups, machine-readable
./warmline-audit --price 3            # add a dollar estimate, given your
                                      # model's base input price per MTok
```

Prints one line per API turn — timestamp, idle gap, cache read/write tokens, verdict —
plus a summary of how much was re-cached cold:

```
time                gap   cache read   cache write  verdict
08-18 10:02:45    6h12m            0        58,427  COLD(ttl)
08-18 10:13:56      10m       62,567           710  HOT

260 API turns; HOT 255  PARTIAL 3  COLD(rebuilt) 1  COLD(ttl) 1
tokens re-cached while cold: 99,188   read from cache: 45,926,103
```

Unlike the statusline (which lags one turn by construction), the audit is
authoritative: it reads the recorded usage of every request. Use it to verify the
keep-warm policy actually kept you warm, or to find out what a `/compact` or an
overnight gap really cost.

## Configuration

| Environment variable | Default | Meaning |
|---|---|---|
| `WARMLINE_TTL_MIN` | `60` | prompt-cache TTL in minutes (set `5` for short-TTL setups) |
| `WARMLINE_STATE_DIR` | `~/.claude/warmline-state` | stamp/state directory |
| `WARMLINE_NO_COLOR` | unset | if set (or `NO_COLOR`), plain output without ANSI colors |
| `WARMLINE_DEBUG` | unset | if set, keeps the last raw statusline payload for inspection |

Set these in the environment Claude Code starts from, or in the `env` block of
`~/.claude/settings.json`. `WARMLINE_TTL_MIN` is honored by both the statusline and
`warmline-audit`.

## Tests

```sh
./test.sh
```

Replays representative statusline payloads (hot, cold-rebuild, TTL-expired, sparse,
garbage, concurrent-session isolation, idle repaints not resetting the clock, a
fresh turn overriding the TTL inference, the expiry countdown, ANSI colors)
against the script, and a synthetic transcript against `warmline-audit`
including the `--price` estimate. The same suite runs in CI on every push.

## License

[MIT](LICENSE)

## Buy me a coffee ☕

BTC: `bc1qjsvtd3dd44llyu4rwz2ucl4kp9wd9kvpsj6tk5`
