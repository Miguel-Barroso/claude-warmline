# Auditing past sessions

[← back to the README](../README.md)

```sh
warmline-audit                      # latest session of the current project
warmline-audit path/to/session.jsonl
warmline-audit --ttl 5 --json       # short-TTL setups, machine-readable
warmline-audit --price 3            # add dollar estimates, given your
                                    # model's base input price per MTok
warmline-audit --all --price 3      # every session on this machine,
                                    # ranked by estimated avoidable premium
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
~/.claude/projects/…/0f83878e.jsonl  (ttl 60m)
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

260 API turns; HOT 255  PARTIAL 3  COLD(rebuilt) 1  COLD(ttl) 1
causes: inactivity+compact 1  /compact 1
tokens re-cached while cold: 99,188   read from cache: 45,926,103
(a cold re-cache bills ~2x base input; a warm wake reads at ~0.1x)
at $3/MTok base input: the cold re-caches cost ~$0.57 more than warm reads of the same tokens would have; cache reads billed ~$13.78
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
  verdict census, then *why* each cold turn happened. (A session's very first
  cache write is graded `session start` and never counted as avoidable; this
  particular session resumed into a still-warm cache, so it has none.)
- The last line, **estimated avoidable premium**, is what the *potentially*
  avoidable cold re-caches cost *over* warm reads of the same tokens (a cold
  re-cache bills ~2×; the warm read it replaced would have billed ~0.1× — a
  1.9× difference). An estimate from recorded token counts, never billing
  data — see ["avoidable", precisely](#what-avoidable-means--precisely).

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
145 sessions under /Users/mb/.claude/projects  (13 more without API turns; ttl 60m)

cache health  █████████████████████████░  95% hot  (10,242 of 10,756 turns)
cold events   187  (152 rebuilt, 35 ttl)

start        project                 turns    hot  part  rebuilt   ttl  avoidable cold    premium
08-07 14:30  MimirBlue                 201    189     6        4     2       1,294,770      $7.38
08-08 10:57  MimirBlue                  66     58     1        4     3         814,630      $4.64
08-11 12:03  MimirBlue                  48     40     1        4     3         624,201      $3.56
   ⋮
TOTAL                                10756  10242   327      152    35      11,661,736     $66.47

causes: inactivity 28  inactivity+compact 7  /compact 7  auto-compact 36  model change 3  unknown 89  session start 56

where the cold came from
  unknown             ██████████████████████████  89
  session start       ████████████████  56
  auto-compact        ███████████  36
  inactivity          ████████  28
  /compact            ██  7
  inactivity+compact  ██  7
  model change        █  3

avoidable cold = tokens re-cached cold, excluding each session's unavoidable first write
premium = estimated avoidable premium of those re-caches vs warm reads (1.9x $3/MTok);
an estimate from recorded token counts, not billing data

estimated avoidable premium ~$66.47  (top 5 sessions: $21.36, other 140: $45.12)
```

How to read it: sessions at the top with big `ttl` counts are keep-warm
candidates — money lost to walking away. Big `rebuilt`/`unknown` counts mean
prefix churn: something rewrote the conversation prefix between turns. Lots of
`auto-compact` means sessions routinely slamming into the context ceiling,
where [compacting earlier and deliberately](../README.md#coming-back-cold-compact-clear-or-neither)
is cheaper. The split on the last line is concentration: is the leak a few
disasters, or spread thin? On this machine, thin — the top five sessions carry
only a third of the premium, which fits the honest headline that silent prefix
drift (`unknown 89`) rebuilt more caches than compaction (43) did. The leak is
rarely where you expect it.

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
  `total` object, including `avoidable_cold_tokens` and, with `--price`,
  `avoidable_premium_usd`.
- `--ttl N` overrides the assumed cache TTL (also `WARMLINE_TTL_MIN`).
