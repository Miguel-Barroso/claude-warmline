# Auditing past sessions

[← back to the README](../README.md)

```sh
warmline-audit --help               # every flag, including the ones below
warmline-audit                      # latest session of the current project
warmline-audit path/to/session.jsonl
warmline-audit --json               # the same report, machine-readable
warmline-audit --ttl 5              # force a TTL instead of detecting it
warmline-audit --price 3            # add dollar estimates, given your
                                    # model's base INPUT price per MTok
                                    # (bare --price = $3; --price-in works too)
warmline-audit --price-out 15       # OUTPUT price per MTok; defaults to
                                    # 5x the input price
warmline-audit --all --price 3      # every session on this machine,
                                    # ranked by estimated avoidable premium
warmline-audit --live               # which sessions are warm right now
warmline watch                      # ...re-rendered live until ctrl-c
```

(Installed into `~/.local/bin/`; from a checkout, `./warmline-audit`.
`warmline audit …` is the same thing.)

Transcripts are read from `$CLAUDE_CONFIG_DIR/projects` (default
`~/.claude/projects`) — where every local front end of the Claude Code engine
records them, so desktop-app sessions are graded alongside terminal ones.
See [where warmline works](SURFACES.md).

Unlike the statusline (which lags one turn by construction), the audit is
authoritative: it grades every recorded API request.

## One session, turn by turn

```
$ warmline-audit --price 3
~/.claude/projects/…/0f83878e.jsonl  (ttl 60m, from its cache buckets)
time                gap   cache read   cache write  verdict
08-17 22:27:52       2m       68,999        20,349  HOT
08-17 22:28:30      <1m       89,348         9,484  HOT
   ⋮
08-17 23:27:21       8m            0        40,761  COLD(rebuilt)  <- /compact
08-17 23:27:53      <1m       18,873        43,431  PARTIAL
   ⋮
08-18 03:50:34      <1m      318,730           449  HOT
08-18 10:02:45    6h12m            0        58,427  COLD(ttl)  <- inactivity+compact
08-18 10:02:53      <1m       58,427         1,123  HOT
   ⋮
08-18 12:04:50      <1m      173,939           746  HOT

cache health  ██████████████████████████  98% hot  (255 of 260 turns)

260 API turns; HOT 255 (98%)  PARTIAL 3 (1.2%)  COLD(rebuilt) 1 (<1%)  COLD(ttl) 1 (<1%)
causes: inactivity+compact 1 (50%)  /compact 1 (50%)
tokens re-cached while cold: 99,188   read from cache: 45,926,103   output: 218,038
(a cold re-cache bills ~2x base input; a warm wake reads at ~0.1x)
at $3/MTok base input: the cold re-caches cost ~$0.57 more than warm reads of the same tokens would have; cache reads billed ~$13.78
output tokens at $15/MTok: ~$3.27 -- output is never cached; cache warmth doesn't change this part of the bill
estimated avoidable premium ~$0.57
```

Reading it, top to bottom:

- **Each row is one API request.** `gap` is the idle time before it; `cache
  read`/`cache write` are the tokens it read from, or re-wrote into, the cache.
- The `/compact` row is a **`COLD(rebuilt)`** with a proven cause: a structured
  compact-boundary marker sits in the transcript right before it. No idle time —
  the prefix rewrite alone killed the cache. The `PARTIAL` right after it is
  typical too: a compact often leaves the shared head of the prefix warm, so
  the next turn reads some cache back while re-writing the rest.
- The `6h12m` row is the expensive one: overnight silence, the cache expired,
  and the first morning message re-wrote 58k tokens at the 2× rate. A
  compaction *also* sits inside that gap, so rather than guess, the auditor
  labels it **`inactivity+compact`** — either could explain the rebuild.
- The **cache health bar** is the fraction of turns that ran hot. Below it, the
  verdict census — each verdict with its share of turns, so the cold events'
  relative weight is readable without division — then *why* each cold turn
  happened, again with each cause's share. (A session's very first cache write
  is graded `session start` and never counted as avoidable; this particular
  session resumed into a still-warm cache, so it has none.)
- The **output line** keeps the bill honest: output tokens are priced at their
  own (higher) rate, and they are never cached — no amount of warmth changes
  that part of the cost. Everything else on this report is input-side.
- The last line, **estimated avoidable premium**, is what the *potentially*
  avoidable cold re-caches cost *over* warm reads of the same tokens (a cold
  re-cache bills ~2× base input; the warm read it replaced would have billed
  ~0.1× — a 1.9× difference). An estimate from recorded token counts, never
  billing data — see ["avoidable", precisely](#what-avoidable-means--precisely).

## Verdicts

| Verdict | Meaning |
|---|---|
| `HOT` | the turn read its prefix from the cache |
| `PARTIAL` | it read some cache but re-wrote more than it read (prefix edited mid-conversation) |
| `COLD(rebuilt)` | nothing read, prefix re-cached, gap within the TTL — an invalidation |
| `COLD(ttl)` | nothing read, prefix re-cached after a gap beyond the TTL |

Subagent (sidechain) turns are excluded: they run on separate prefixes, and
their transcripts live in separate nested files that `--all` skips.

## Causes

Causes are attribution, not guesswork:

| Cause | Where it comes from |
|---|---|
| `session start` | the first turn of a session always writes its prefix |
| `/compact`, `auto-compact` | a structured `compact_boundary` marker with its trigger recorded |
| `compact` | a boundary marker without metadata — certainly a compaction, manual-vs-auto would be a guess |
| `model change` | the model recorded on the turn differs from the previous turn's |
| `inactivity` | the `COLD(ttl)` case |
| `inactivity+compact` | both happened inside the same gap; either explains it |
| `unknown` | a rebuild the transcript can't explain — in practice mostly prefix drift (an edited CLAUDE.md, changed git state, MCP availability) |

## Where does the money leak? `--all`

`--all` audits every session under `~/.claude/projects` (or a directory you
pass), one line per session, ranked by **avoidable cold tokens**. Real output
from one machine's 8 weeks of history:

```
$ warmline-audit --all --price 3
147 sessions under /Users/mb/.claude/projects  (13 more without API turns; ttl per session from its cache buckets, 60m fallback)

cache health  █████████████████████████░  95% hot  (10,394 of 10,921 turns)
cold events   198  (159 rebuilt, 39 ttl) -- 1.8% of all turns

start        project                 turns    hot  part  rebuilt   ttl  avoidable cold  share    premium
08-07 14:30  MimirBlue                 201    189     6        4     2       1,294,770    11%      $7.38
08-08 10:57  MimirBlue                  66     58     1        4     3         814,630   6.7%      $4.64
08-11 12:03  MimirBlue                  48     40     1        4     3         624,201   5.1%      $3.56
   ⋮
TOTAL                                10921  10394   329      159    39      12,134,109   100%     $69.16

causes: inactivity 31 (13%)  inactivity+compact 8 (3.4%)  /compact 7 (3.0%)  auto-compact 37 (16%)  model change 3 (1.3%)  unknown 92 (39%)  session start 59 (25%)

where the cold came from
  unknown             ██████████████████████████  92 (39%)
  session start       █████████████████  59 (25%)
  auto-compact        ██████████  37 (16%)
  inactivity          █████████  31 (13%)
  inactivity+compact  ██  8 (3.4%)
  /compact            ██  7 (3.0%)
  model change        █  3 (1.3%)

avoidable cold = tokens re-cached cold, excluding each session's unavoidable first write
premium = estimated avoidable premium of those re-caches vs warm reads (1.9x base input $3/MTok);
an estimate from recorded token counts, not billing data
input-side only: the 10,846,481 output tokens across these sessions bill at $15/MTok warm or cold

estimated avoidable premium ~$69.16  (top 5 sessions: $21.36, other 142: $47.81)
```

How to read it: the percentages do the ranking for you. In the cause histogram,
each cause carries its share of all cold-cause events — here 39% of the cold
came from `unknown` (prefix drift), 16% from `auto-compact`, 13% from walking
away past the TTL — so the events most likely to cost you are obvious at a
glance, raw counts preserved beside them. The `share` column is each session's
slice of all avoidable cold tokens: the top session alone holds 11% of the
leak. Sessions at the top with big `ttl` counts are keep-warm candidates —
money lost to walking away. Big `rebuilt`/`unknown` counts mean prefix churn:
something rewrote the conversation prefix between turns. Lots of `auto-compact`
means sessions routinely slamming into the context ceiling, where
[compacting earlier and deliberately](../README.md#coming-back-cold-compact-clear-or-neither)
is cheaper. The split on the last line is concentration: is the leak a few
disasters, or spread thin? On this machine, thin — the top five sessions carry
less than a third of the premium, which fits the honest headline that silent
prefix drift (`unknown`, 39%) rebuilt more caches than compaction (44 events,
19%) did. The leak is rarely where you expect it.

## Which sessions are warm right now? `--live` / `warmline watch`

Everything above grades the past. `--live` answers the present: every session
with API turns in the last 24 hours, whether the prompt cache still holds its
prefix, and when that ends — computed from last-turn timestamps and each
session's TTL, so unlike the statusline it has no one-turn lag and no repaint
dependency. It covers desktop-app sessions too, which write the same
transcripts but have no statusline surface at all.

```
$ warmline-audit --live
live cache warmth  20:46:24  (5 sessions with API turns in the last 24h)

state                    project                session   last turn   turns    ctx
WARM  cold ~21:38 (52m)  MimirBlue              ae43c47c  20:38          10    90k
WARM  cold ~21:46 (60m)  claude-warmline        cd808a8d  20:46          63   193k
cold  since 11:56        MimirBlue              324c6642  10:56          64   151k
cold  since 00:05        claude-warmline        5059cbd6  Wed 23:05      86    48k
cold  since Wed 23:01    claude-warmline        d149945f  Wed 22:01      75   260k

WARM = the cache still holds that session's prefix: resuming now
reads it at ~0.1x; after it goes cold the next turn re-caches at ~2x.
```

(That `cold  since 11:56` row is the exact failure the statusline used to
hide: a session whose terminal still showed a frozen green `HOT` at 8 pm —
see [staying current while idle](STATUSLINE.md#staying-current-while-idle).)

Warm sessions sort first, soonest-to-die on top (yellow inside 15 minutes) —
if you mean to resume one, that's the order to do it in. `warmline watch
[-n SECS]` re-renders this every 10 seconds until ctrl-c; `--live --json`
is the scriptable form.

## The TTL is auto-detected

Every cache write in a transcript records which bucket it went to
(`ephemeral_1h` or `ephemeral_5m`), so the auditor grades each session
against the TTL its own writes prove — no flag needed, sessions with
different TTLs audit correctly side by side, and the header says which was
used (`from its cache buckets`, `default`, or `forced`). `--ttl N` /
`WARMLINE_TTL_MIN` force one for every session; 60m is the fallback for
transcripts that predate bucket recording.

## Pricing: input and output are different prices

Claude bills input and output tokens at different rates, so the auditor never
treats "a token" as one price:

- **`--price N`** (alias `--price-in`) is your model's **base input** price in
  $/MTok. Everything cache-related is a multiple of it: warm reads bill ~0.1×,
  a 1h-TTL cold re-cache ~2×, and the avoidable premium is the 1.9× difference.
- **`--price-out N`** is the **output** price in $/MTok. Output tokens are
  never cached — warmth doesn't change what they cost — so they get their own
  clearly-labeled line, and the cache numbers can't be mistaken for the whole
  bill.

Both numbers are optional, with defaults from the current Claude API price
sheet: a bare `--price` uses **$3/MTok** (the Claude Sonnet base input price),
and an omitted `--price-out` defaults to **5× the input price** — the
input:output ratio every current Claude model bills at:

| Model | input $/MTok | output $/MTok |
|---|---|---|
| Claude Fable 5 | 10 | 50 |
| Claude Opus | 5 | 25 |
| Claude Sonnet *(the default)* | 3 | 15 |
| Claude Haiku | 1 | 5 |

So on a mostly-Opus history, `--price 5` is the only flag you need — the
output rate follows along at $25.

## What "avoidable" means — precisely

Every session must pay for its first cache write: a conversation has to be
cached once before anything can ever be read back cheaply. warmline never
counts that. What it counts as *avoidable* is every token re-cached cold
**after** that point — rebuilds caused by TTL expiry, compaction, or prefix
drift, which different timing (a keep-warm ping, an earlier deliberate
`/compact`, a stable prefix) *might* have prevented.

That makes the number an estimate of exposure, not money actually wasted: some
of it is unpreventable in practice (a TTL expiry while your laptop was asleep
counts as "avoidable", though no ping could have fired), and all of it is
computed from token counts recorded in your transcripts — warmline never sees,
and cannot see, what Anthropic actually billed your account.

## Output modes

- Bars and colors are TTY-gated: piped or CI output stays plain. `NO_COLOR` /
  `WARMLINE_NO_COLOR` force plain; `WARMLINE_FORCE_COLOR` forces color without
  a TTY (the opt-outs still win).
- `--json` is byte-stable and never decorated — per-session records plus a
  `total` object, including `avoidable_cold_tokens`, `tokens_output`, each
  session's `ttl_min`/`ttl_source`, and, with `--price`,
  `avoidable_premium_usd` plus the `price_in_per_mtok`/`price_out_per_mtok`
  the run used. Percentages are a display convenience only — the JSON carries
  the raw counts. It combines with `--all` and `--live`, and it is the form to
  reach for when something other than a human is reading: an agent auditing its
  own session, CI, or a terminal proxy that reflows the table's columns.
- `--ttl N` forces the cache TTL for every session (also `WARMLINE_TTL_MIN`);
  unset, it is [auto-detected per session](#the-ttl-is-auto-detected).
- `--help` prints all of the above. (Before v1.8.0 it didn't — `--help` was
  parsed as a transcript path and died, which is how `--json` stayed a
  grep-only discovery.)
