# What we measured (not modeled)

[← back to the README](../README.md)

Every claim warmline makes is checkable against real transcripts — Claude Code
records `cache_read_input_tokens` and `cache_creation_input_tokens` for every
API turn, and [`warmline-audit`](AUDIT.md) grades them.

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

`warmline-audit --all` over 145 sessions puts the total estimated avoidable
premium at **~$66** at Sonnet base pricing — and attributes 43 cache rebuilds
to compaction but **89 to unexplained prefix drift**. The leak is rarely where
you expect it.

## Measure your own

```sh
warmline-audit --all --price 3     # your machine, your models' base price
warmline-audit --price 3           # this session, turn by turn
```

The numbers above are estimates computed from token counts recorded in
transcripts, not billing data — see
["avoidable", precisely](AUDIT.md#what-avoidable-means--precisely).
