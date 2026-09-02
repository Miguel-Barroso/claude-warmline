# What we measured (not modeled)

[← back to the README](../README.md)

Every claim warmline makes is checkable against real transcripts — Claude Code
records `cache_read_input_tokens` and `cache_creation_input_tokens` for every
API turn, and [`warmline audit`](AUDIT.md) grades them.

## A real 13-hour session

2026-08-18, ~300k context, merge-queue babysitting with background CI watchers:

- **260 API turns: 255 HOT, 1 COLD(rebuilt), 1 COLD(ttl)** — 45.9M tokens read
  from cache; only 99k tokens ever re-cached cold.
- Background task notifications arriving every ~9 minutes kept the cache hot
  for four straight hours at **~400 tokens of cache-write per wake** (reads
  meanwhile grew from 150k to 317k). **If background work is in flight, its
  notifications keep the cache warm for free** — no policy needed. This is why
  keep-warm deliberately skips that case.
- The one `COLD(ttl)` came after a 6-hour overnight silence — the machine was
  asleep, so nothing could have fired. **No scheduled wakeup survives a closed
  lid** (on macOS, `caffeinate` is the workaround for planned long waits).
- The one `COLD(rebuilt)` followed `/compact`: a full 58k-token re-cache within
  minutes of activity. Prefix invalidation and TTL expiry are different failure
  modes, which is exactly why the statusline distinguishes them.

## A 4.5-hour session with the policy on

2026-08-31, supervising a 104 GB phone-to-server backup — mostly waiting:

- **187 API turns: 179 HOT (96%), 8 PARTIAL, 0 COLD.** 16.1M tokens read from
  cache; **0 tokens re-cached while cold.** The policy did what it claims.
- **Every one of the 8 warmth breaks was an auto-compaction**, not a TTL
  expiry and not a `/compact` anyone typed. Three fired at 167–169k input
  tokens — about **84% of a 200k window** — which is where the statusline's
  yellow `ctx` threshold comes from. See
  [auto-compact](KEEP-WARM.md#auto-compact-the-one-you-dont-choose).
- **The available wakeup mechanism was none of the ones the policy named.**
  No `ScheduleWakeup`, no `/loop`; one-shot cron entries with manual cleanup.
  The policy now states the requirement rather than a list of tools.
- **Two in-harness background tasks died mid-wait** (~25 and ~78 minutes) with
  a bare `[killed]` and no error text. Host sleep, device disconnection and
  transfer errors were each ruled out; harness lifecycle is an inference, not
  a proven cause. What worked was a detached worker paired with a short-lived
  in-harness poller — now shipped as
  [`warmline wait-for`](KEEP-WARM.md#waiting-on-work-you-launched-yourself-warmline-wait-for).

## The TTL, measured in a clean room

Two isolated headless sessions, no MCP servers, frozen environment:

- After **50 minutes** of total silence, a probe read its full 71,312-token
  prefix from cache and wrote only 56 tokens.
- After **70 minutes**, an identical session found its cache gone and re-wrote
  all 45,033 tokens.

Warm at 50, cold at 70 — the 1-hour TTL is real, and keep-warm's ~50-minute
ping interval sits safely inside it. Headless probes also confirm the bucket:
Claude Code writes the cache with `ephemeral_1h`, and a resumed session reads
its full prefix back (33,614 tokens read, 56 written, in the reference probe).

**Reads refresh the TTL.** The cold arm's probe still found the shared system
block warm, because the other arm had read that block 20 minutes earlier. A
keep-warm ping is exactly that refresh, applied to your whole prefix.

## Prefix stability matters as much as TTL

An earlier, deliberately-dirty run of the same experiment surfaced a subtler
failure mode: a headless `--resume` regenerates the whole system prompt, so
git-status drift, MCP server availability, or an edited CLAUDE.md between turns
silently diverges the prefix — and everything past the divergence re-caches at
full price. No keep-warm ping can help a session whose prefix churns between
turns.

## Eight weeks of one machine's history

`warmline audit --all` over 147 sessions puts the total estimated avoidable
premium at **~$69** at Sonnet base input pricing — an estimate of exposure
computed from token counts in those transcripts, **not billing data**, and one
that excludes each session's unavoidable first cache write while still counting
some cold nobody could have prevented (see
["avoidable", precisely](AUDIT.md#what-avoidable-means--precisely)). The same
run attributes 19% of the cold-cause events to compaction and leaves **39%
unattributed** — a residual bucket the transcript gave no proof for, not a
named cause. The leak is rarely where you expect it.

Re-run today with derived pricing — `warmline audit --all --price`, each
project at its own solved rate and each session at its own cache bucket — the
130 sessions still on disk total **~$63**. The method changed more than the
history did: a single assumed $3 replaced by real per-project rates, and 1.9×
replaced by 1.15× wherever a session ran on the 5-minute bucket.

## Every price tier bills the same multiples

The pricing catalog shipped inside Claude Code 2.1.252 carries seven tiers —
`tier_2_10`, `tier_3_15`, `tier_5_25`, `tier_10_50`, `tier_15_75`, `haiku_35`,
`haiku_45`. Every one of them is the same shape:

| Billed item | Multiple of that tier's base input price |
|---|---|
| output | **5×** |
| 1-hour cache write | **2×** |
| 5-minute cache write | **1.25×** |
| cache read | **0.1×** |
| web search | flat $0.01 per request, every tier |

That identity is what lets warmline price a cache without knowing which model
ran. Two consequences it now acts on:

- **The avoidable premium of going cold is `write − read`:** **1.9×** base input
  on the 1-hour bucket, **1.15×** on the 5-minute one. Up to v2.1.0 the auditor
  applied 1.9× to everything, which overstated a 5-minute session by ~65%; it
  now uses the bucket each session actually recorded.
- **Warm reads are cheap in the same proportion everywhere.** A ping costs 0.1×
  input whatever you run; the rebuild it prevents costs 2× on the long bucket.

## Where auto-compact actually fires

Claude Code reserves `min(max_output, 20000) + 13000` tokens at the top of the
window for the compaction it triggers itself. Every current model's `max_output`
is at least 20000, so the reserve is a flat **33000 tokens** and the threshold is
`context_window_size − 33000`:

| Window | Compacts at | As a percentage |
|---|---|---|
| 200k | 167,000 | 83.5% |
| 1M | 967,000 | 96.7% |

The field measurement that produced warmline's old 80% warning (compaction seen
firing at 167–169k of a 200k window) was reading exactly this line, one window
size at a time. The statusline now computes it instead: same warning in a 200k
window, silence in a 1M one where 86% is still 100k of headroom.

## Your own price, without a price sheet

Claude Code writes its own cost accounting to `~/.claude.json`: each
`projects[<dir>]` entry records `lastCost` beside the token counts that produced
it. With the multiples above, that solves for the base input price of whatever
you actually ran:

```
p_in = (lastCost − 0.01 × web_requests)
       ÷ (input + 5×output + 2×cache_write + 0.1×cache_read) × 1e6
```

Across the 11 projects with a cost record on the development machine, the solved
rates run **$1.99 to $4.86/MTok**. Three of them are the arithmetic checking
itself: two pure-Sonnet projects come out at **$3.00 and $2.998** — the
`tier_3_15` list price — and one Haiku-heavy project at **$1.99**, landing on
`tier_2_10`. The rest sit between tiers because those sessions mixed models,
which is the honest answer for a mixed session and the one a baked price table
cannot give.

This is why warmline ships no price sheet. A table would go stale, and it would
misprice the moment you switched from Sonnet to Opus. `warmline audit --price`
re-solves per project, per run, and prints where the number came from.

## Measure your own

```sh
warmline audit --all --price       # your machine, at your own solved rate
warmline audit --price             # this session, turn by turn
warmline audit --price 3           # ...or override the base input rate
warmline audit --price 3 --price-out 15   # output priced explicitly
                                          # (omitted, it defaults to 5x input)
```

The numbers above are estimates computed from token counts recorded in
transcripts, not billing data — see
["avoidable", precisely](AUDIT.md#what-avoidable-means--precisely).
