# Auditing past sessions

[← back to the README](../README.md)

```sh
warmline audit --help               # every flag, including the ones below
warmline audit                      # latest session of the current project
warmline audit path/to/session.jsonl
warmline audit --json               # the same report, machine-readable
warmline audit --ttl 5              # force a TTL instead of detecting it
warmline audit --price              # dollar estimates at YOUR rate, solved
                                    # from Claude Code's own cost record
warmline audit --price 3            # ...or override the base INPUT price
                                    # per MTok (--price-in works too)
warmline audit --price-out 15       # OUTPUT price per MTok; defaults to
                                    # 5x the input price
warmline audit --all --price        # every session on this machine, ranked
                                    # by avoidable cold tokens, each project
                                    # at its own derived rate
warmline audit --cold-at            # one line for a poller: when this
                                    # session's cache expires, which bucket
warmline audit --live               # which sessions are warm right now
warmline watch                      # ...re-rendered live until ctrl-c
```

**Two spellings, one program.** `warmline audit …` is the primary form — one
command, discoverable from `warmline --help`. It runs `warmline-audit`, the
executable the installer puts in `~/.local/bin/`, which stays fully supported
and is the form to use in scripts you've already written, from a checkout
(`./warmline-audit`), and on [manual/Windows installs](INSTALL.md#windows),
where the `warmline` wrapper (bash) isn't available. Nothing is deprecated;
error messages print the program's own name, `warmline-audit`.

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
(a cold re-cache bills ~2x base input on this session's 1h cache; a warm wake reads at ~0.1x)
input $3/MTok as given on the command line
the cold re-caches cost ~$0.57 more than warm reads of the same tokens would have; cache reads billed ~$13.78
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
- **The price line says where the price came from.** With a bare `--price` it
  is solved from Claude Code's own cost record for this project; with `--price
  N` it says so; with neither readable it says `ASSUMED`. See
  [pricing](#pricing-your-rate-not-a-price-sheet).
- **Two dollar figures, and they usually differ.** The `cold re-caches cost`
  line prices *every* cold re-cache in the session. The closing **estimated
  avoidable premium** prices the same re-caches **minus each session's first
  cache write**, which no session can avoid. Both read `$0.57` here only because
  this session resumed into a still-warm cache and never paid a session-start
  write; a session that starts cold shows the first number higher than the
  second (a real one on the same machine: `~$0.67` against `~$0.48`). Either way
  the figure is what cold re-caching cost *over* warm reads of the same tokens —
  a cold re-cache bills ~2× base input where the warm read it replaced would
  have billed ~0.1×, a 1.9× difference on this session's 1-hour bucket (1.15×
  had it been on the 5-minute one) — and both are estimates of **exposure**
  computed from recorded token counts, never billing data. See
  ["avoidable", precisely](#what-avoidable-means--precisely).

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
| `claude upgrade` | the Claude Code build recorded on the entry (its `version` field) differs from the previous turn's — an upgrade rewrites the system prompt and tools, so the prefix provably changed. When a model change proves the same turn, `model change` is reported: the tie-break is fixed, so the verdict never flips between runs. Transcripts that predate version recording claim nothing |
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
premium = estimated avoidable premium of those re-caches vs warm reads (1.9x base input, per session's own cache bucket);
an estimate from recorded token counts, not billing data
input $3/MTok as given on the command line
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
[compacting earlier and deliberately](#when-you-come-back-cold)
is cheaper. The split on the last line is concentration: is the leak a few
disasters, or spread thin? On this machine, thin — the top five sessions carry
less than a third of the premium, which fits the honest headline that silent
prefix drift (`unknown`, 39%) rebuilt more caches than compaction (44 events,
19%) did. The leak is rarely where you expect it.

## When you come back cold

The audit tells you where the cold happened. This is what to do when you are
staring at one — a `COLD(ttl?)` on the statusline, or a big context you know has
gone quiet past its TTL. The cache is gone; whatever you do next, that context
gets processed once more at the expensive uncached rate. The only question is
what that one unavoidable pass buys you:

- **You still need the conversation history → `/compact`.** Compaction must read
  the whole conversation once to summarize it. On a warm cache that read would be
  cheap — but it would also destroy a cache you already paid 2× to build, which is
  why compacting while `HOT` is the worst-timed move (unless you're out of context
  window and have no choice). On a cold cache the expensive pass was going to
  happen on your very next message anyway — compaction just redirects it into
  producing a small summary, so from then on you cache and carry a few thousand
  tokens instead of 100k+. `/compact` has the most benefit exactly when the cache
  is already dead.
- **Your state is written down outside the conversation → `/clear`.** If what you
  need lives in memory files, a plan document, or the code and git history,
  `/clear` skips even the summarization pass — nothing ever pays to read the old
  context again. A fresh session's prefix is just the system prompt, your
  CLAUDE.md, and the memory index; files are re-read only as they become
  relevant, which is almost always far cheaper than one summarization pass over
  a 100k+ conversation.
- **Small context → do nothing.** Going cold on 20k tokens is cheap to rebuild.
  Everything here exists for the 100k+ case.

The same reasoning explains the `auto-compact` rows in your audit: a compaction
you didn't choose, fired near the context ceiling, rewrites the prefix at
whatever moment it happens — including while the cache was warm. See
[auto-compact: the one you don't choose](KEEP-WARM.md#auto-compact-the-one-you-dont-choose).

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

## Pricing: your rate, not a price sheet

**warmline ships no price table.** A table goes stale, and it is wrong the
moment you switch models — the same session priced as Sonnet and as Opus is off
by 67%. A bare `--price` instead *solves* for the base input rate you are
actually paying, from the cost accounting Claude Code writes for itself:

```
p_in = (lastCost − $0.01 × web_searches)
       ÷ (input + 5×output + 2×cache_write + 0.1×cache_read) × 1e6
```

Those multiples are not warmline's assumption: every pricing tier Claude Code
ships bills output at 5×, a 1-hour cache write at 2×, a 5-minute write at 1.25×
and a warm read at 0.1× of its own base input price — identical across all
seven ([the table](MEASUREMENTS.md#every-price-tier-bills-the-same-multiples)).
The inputs come from `~/.claude.json`'s entry for the project (`lastCost` and
the token totals beside it), so a model switch moves the number by itself.

Where the number came from is printed with it, every time:

```
input $4.17/MTok, derived from Claude Code's own cost for the last session in claude-warmline ($63.70 over 15.2 MTok input-equivalent) -- no price sheet, so it follows the models you actually run
input $10/MTok as given on the command line
input $3/MTok ASSUMED (Sonnet tier): Claude Code's own cost record wasn't readable, so this is a placeholder, not your price
```

`--all` goes one step further and prices **each project's sessions at that
project's own derived rate** — the only honest way to total a history that mixed
Opus, Sonnet and Haiku across different repos. Sessions in a project with no
cost record fall back to the run's headline rate.

- **`--price N`** (alias `--price-in`) overrides the derivation with a **base
  input** price in $/MTok. Everything cache-related is a multiple of it: warm
  reads bill ~0.1×, a cold re-cache 2× on the 1-hour bucket (1.25× on the
  5-minute one), and the avoidable premium is the difference — **1.9× or
  1.15×**, per the bucket that session actually used.
- **`--price-out N`** is the **output** price in $/MTok, defaulting to **5×
  input**. Output tokens are never cached — warmth doesn't change what they
  cost — so they get their own clearly-labeled line, and the cache numbers
  can't be mistaken for the whole bill.
- `--json` carries `price_source` (`derived` / `flag` / `assumed`) so a script
  can tell a solved number from a placeholder.

The $3 placeholder survives for exactly one case — no readable cost record —
and says `ASSUMED` when it is what got used.

## What "avoidable" means — precisely

Every session must pay for its first cache write: a conversation has to be
cached once before anything can ever be read back cheaply. warmline never
counts that. What it counts as *avoidable* is every token re-cached cold
**after** that point — rebuilds caused by TTL expiry, compaction, or prefix
drift, which different timing (a keep-warm ping, an earlier deliberate
`/compact`, a stable prefix) *might* have prevented.

**Read it as a measure of exposure, not of money actually wasted.** The word
"avoidable" in the printed label marks one specific exclusion — each session's
unavoidable first write — and nothing more. It is not a claim that everything
counted could have been prevented, and a fair amount of it could not have been:
a TTL expiry while your laptop was asleep is counted, though no ping could have
fired; so is an `auto-compact`, which
[nothing prevents](KEEP-WARM.md#auto-compact-the-one-you-dont-choose) once the
context window fills. What the number is good for is comparison and ranking —
which sessions, and which causes, carry your exposure — not a refund estimate.

And all of it is computed from token counts recorded in your own transcripts:
warmline never sees, and cannot see, what Anthropic actually billed your
account.

## Output modes

- Bars and colors are TTY-gated: piped or CI output stays plain. `NO_COLOR` /
  `WARMLINE_NO_COLOR` force plain; `WARMLINE_FORCE_COLOR` forces color without
  a TTY (the opt-outs still win).
- `--json` is byte-stable and never decorated. Percentages are a display
  convenience only — the JSON carries the raw counts. It combines with `--all`
  and `--live`, and it is the form to reach for when something other than a
  human is reading: an agent auditing its own session, CI, or a terminal proxy
  that reflows the table's columns. The shape differs by mode:
  - **`--all --json`** — per-session records plus a `total` object, including
    `avoidable_cold_tokens`, `tokens_output`, each session's
    `ttl_min`/`ttl_source`, and, with `--price`, `avoidable_premium_usd` (on
    both the sessions and the total), each session's own
    `price_in_per_mtok`, and the run's headline
    `price_in_per_mtok`/`price_out_per_mtok` plus `price_source`.
  - **single-session `--json`** — a `summary` object plus one record per turn.
    With `--price` the summary carries `cold_extra_usd` (every cold re-cache,
    session-start write included), `cache_read_usd` and `output_usd`. Note that
    `avoidable_premium_usd` is currently emitted by `--all --json` only; for one
    session, derive it from `avoidable_cold_tokens` (× `premium_x` ×
    `price_in_per_mtok` ÷ 1e6), which is the figure the human report prints on
    its closing line. `premium_x` and `cache_bucket` are in the summary, so the
    1.9×/1.15× choice never has to be guessed.
- `--ttl N` forces the cache TTL for every session (also `WARMLINE_TTL_MIN`);
  unset, it is [auto-detected per session](#the-ttl-is-auto-detected).
- `--help` prints all of the above. (Before v1.8.0 it didn't — `--help` was
  parsed as a transcript path and died, which is how `--json` stayed a
  grep-only discovery.)
