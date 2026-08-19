# claude-warmline

**English** | [日本語](README.ja.md) | [繁體中文](README.zh-TW.md) | [简体中文](README.zh-CN.md)

[![tests](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml/badge.svg)](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml)
[![version](https://img.shields.io/github/v/tag/Miguel-Barroso/claude-warmline?label=version)](https://github.com/Miguel-Barroso/claude-warmline/tags)
[![license](https://img.shields.io/github/license/Miguel-Barroso/claude-warmline)](LICENSE)

**See when Claude Code quietly re-processes your entire conversation — and prevent the avoidable part.**

Lightweight observability for Claude Code's hidden context/cache economics:
a statusline, an auditor, and an optional keep-warm policy. No dependencies
beyond `python3` and `bash`; nothing phones home — everything is read from
data Claude Code already records on your machine.

![The warmline statusline in its three states: cache HOT in green, cache COLD(rebuilt) in yellow, cache COLD(ttl?) in red](docs/statusline.svg)

## The 30-second version

Claude doesn't remember anything between messages. Every time you press enter,
Claude Code re-sends the *entire* conversation so far — system prompt, tools,
every file it read, every reply. On a long session that's easily 100k+ tokens
of input, every single turn.

What makes this affordable is a server-side **prompt cache**. Think of it as a
workspace Claude has already set up for your conversation: while the workspace
stands, each new message *reads* it at roughly **0.1×** the normal input price.
Setting it up costs about **2×** — paid once, then amortized over every turn.
That's why a busy session feels fast and cheap even at 200k context.

The catch: the workspace is quietly torn down after **about an hour of
inactivity**. Come back to a big session after lunch, and your next message
rebuilds all of it at the 2× rate — at exactly the moment you wanted results.
It's also torn down *without* any idle time whenever the start of the
conversation is rewritten: `/compact` reorganizes the whole workspace, so it
always triggers a full rebuild.

Claude Code doesn't surface any of this. warmline makes it visible — and helps
prevent the part that's avoidable.

## Quick start

```sh
curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash

warmline keep-warm on        # optional: prevent avoidable cold starts
warmline keep-warm status    # is it on?
```

Then use Claude Code normally — the statusline shows the cache state live.
When you want to know what a session (or all of them) actually cost:

```sh
warmline-audit               # this session, turn by turn
warmline-audit --all         # every session, ranked by where the money leaked
```

## What warmline answers

| | Question |
|---|---|
| **statusline** | What's happening right now? (`cache HOT` / `COLD`, live) |
| **`warmline-audit`** | What happened in this session, turn by turn? |
| **`warmline-audit --all`** | Where is my usage leaking money, across all sessions? |
| **cause attribution** | *Why* did the cache go cold — idle, `/compact`, drift? |
| **keep-warm** (optional) | Can I prevent the avoidable cold starts? |

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

What lands where: `statusline.py` → `~/.claude/warmline-statusline.py`, wired
into `~/.claude/settings.json` (backed up first; an existing custom statusline
is never replaced without `--force`); the `warmline` and `warmline-audit`
commands → `~/.local/bin/` (override with `WARMLINE_BIN_DIR`); the keep-warm
policy text → `~/.claude/warmline-keep-warm.md`. Claude Code usually picks the
statusline up within seconds — restart the session if it doesn't.

If `~/.local/bin` isn't on your `PATH`, the installer says so and prints the
exact line to add (`export PATH="$HOME/.local/bin:$PATH"`) — it never edits
your shell startup files itself.

| Flag | Effect |
|---|---|
| `--keep-warm` | install-time shorthand for [`warmline keep-warm on`](#keep-warm) |
| `--force` | replace an existing non-warmline statusline |
| `--uninstall` | remove everything the installer added, including the policy block |
| `--help` | usage |

Requires `python3` (standard library only) and `bash`. To pass flags through
the `curl` form: `curl -fsSL …/install.sh | bash -s -- --keep-warm`.

**The installer installs warmline. The `warmline` command controls it.** At
any time, one command answers "what is warmline doing on this machine?":

```
$ warmline status
claude-warmline status  (config: /Users/mb/.claude)
  statusline  ON   /Users/mb/.claude/warmline-statusline.py
  keep-warm   OFF  (enable: warmline keep-warm on)
  auditor     ON   /Users/mb/.local/bin/warmline-audit
  ttl         60m (default)
```

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
you've spent anything. Gaps are tracked per session (stamp files in
`~/.claude/warmline-state/`), so concurrent sessions don't reset each other's clock.

The practical use: `COLD(ttl?)` on a big `ctx` marks the cheapest possible moment
to change course — see [Coming back cold](#coming-back-cold-compact-clear-or-neither).

## Auditing past sessions

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

Unlike the statusline (which lags one turn by construction), the audit is
authoritative: it grades every recorded API request. A real session:

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
  data — ["avoidable", precisely](#where-does-the-money-leak---all).

Causes are attribution, not guesswork: `/compact` and `auto-compact` come from
structured markers in the transcript, `model change` from the recorded model,
`inactivity+compact` labels the ambiguous case where either explains it, and
everything else is honestly `unknown` — in practice mostly prefix drift (an
edited CLAUDE.md, changed git state, MCP availability) the transcript can't prove.

### Where does the money leak? `--all`

`--all` audits every session under `~/.claude/projects` (or a directory you
pass), one line per session, ranked by **avoidable cold tokens** — a term with
a precise meaning here, defined right below the output. Real output from this
machine's 8 weeks of history:

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

**What "avoidable" means — precisely.** Every session must pay for its first
cache write: a conversation has to be cached once before anything can ever be
read back cheaply. warmline never counts that. What it counts as *avoidable*
is every token re-cached cold **after** that point — rebuilds caused by TTL
expiry, compaction, or prefix drift, which different timing (a keep-warm ping,
an earlier deliberate `/compact`, a stable prefix) *might* have prevented.
That makes the number an estimate of exposure, not money actually wasted: some
of it is unpreventable in practice (a TTL expiry while your laptop was asleep
counts as "avoidable", though no ping could have fired), and all of it is
computed from token counts recorded in your transcripts — warmline never sees,
and cannot see, what Anthropic actually billed your account.

How to read it: sessions at the top with big `ttl` counts are keep-warm
candidates — money lost to walking away. Big `rebuilt`/`unknown` counts mean
prefix churn: something rewrote the conversation prefix between turns. Lots of
`auto-compact` means sessions routinely slamming into the context ceiling,
where compacting earlier and deliberately (see below) is cheaper. The split on
the last line is concentration: is the leak a few disasters, or spread thin?
On this machine, thin — the top five sessions carry only a third of the
premium, which fits the honest headline that silent prefix drift (`unknown
89`) rebuilt more caches than compaction (43) did. The leak is rarely where
you expect it.

Piped or CI output stays plain (bars and colors are TTY-gated), and `--json`
is unchanged and machine-readable.

## Keep Warm

Everything above *observes*. Keep Warm is the optional half that *prevents*:
it keeps the cache from expiring during long waits you intend to come back to.

```sh
warmline keep-warm on        # turn it on (once)
warmline keep-warm status    # is it on?
warmline keep-warm off       # turn it off
```

That's it. It's global (one block in `~/.claude/CLAUDE.md`), applies to every
project, and persists across sessions and installer updates — set and forget.
(`./install.sh --keep-warm` runs the same enable at install time;
`--uninstall` removes it along with everything else.)

```
$ warmline keep-warm status
keep-warm  ON
  scope    global -- applies to every project  (block in /Users/mb/.claude/CLAUDE.md)
  policy   intact
```

`status` never trusts a state file — it reads your actual CLAUDE.md every
time. Hand-delete the block and it reports OFF; leave half a block behind and
it reports INCONSISTENT, with the fix, rather than a false ON. For scripts,
the exit code is the answer: `0` on, `1` off, `2` inconsistent.

**What it is:** a short, marker-delimited instruction block
([`keep-warm.md`](keep-warm.md)) that your agent follows during active
sessions. When it starts background work expected to exceed ~45 minutes while
context is substantial, it schedules a wakeup ~50 minutes out; on wake, it
reschedules if the work is still running, otherwise continues normally — and
results land against a hot cache. Each ping costs ~0.1× your context in
cache-read quota vs ~2× for the cold re-write, so it pays for itself for idle
stretches up to roughly 10–12 hours *if* you return.

**What it is NOT:**

- **Not a daemon.** No background process, no cron, no requests outside a
  running Claude Code session. When Claude Code isn't running, nothing runs.
- **Not always-on.** It deliberately *skips* when local background tasks are
  already in flight (their notifications keep the cache warm for free —
  measured below), and skips small contexts, where going cold is cheap.
- **Not persistent past the wait.** Wakeups are deleted the moment work
  resumes, and a single wait gives up after ~12 reschedules (~10 hours) —
  past that the pings cost more than the rebuild they prevent.

**When it cannot operate:** wakeups can't fire while the host machine sleeps
(on macOS, `caffeinate -is` keeps a planned wait awake). `ScheduleWakeup` may
be absent or gated on some Claude Code builds — the agent then falls back to a
recurring scheduled prompt (`/loop 50m <ping>`), or the block is simply inert.
And it's an instruction, not code: the agent can fail to follow it. The audit
is how you verify it actually worked.

**Is this within Anthropic's terms?** We researched this rather than assuming.
The mechanism keep-warm relies on is documented product behavior: Anthropic's
[prompt-caching docs](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)
state the cache "is refreshed at no additional cost each time the cached
content is used", and for API use they explicitly recommend periodic pre-warm
requests. A keep-warm ping is an ordinary billed request inside a live session:
it consumes your own quota (usually *less* than the cold rebuild it replaces)
and bypasses nothing. The boundary that matters is on the other side —
Anthropic's weekly limits exist to curb accounts running Claude Code
continuously, 24/7. That is why this policy is bounded by design: it pings only
through a genuine wait you intend to return to, at most about once per 50
minutes, skips when warmth is already free, stops the moment work resumes,
gives up after ~10 hours, and is never a daemon. Don't loosen those bounds.
One honest unknown remains: whether scheduled pings inside a consumer Claude
Code session count as the "ordinary, individual usage" the subscription plans
assume is not addressed anywhere we could find — Anthropic's exact position on
this specific use is unknown. None of this means Anthropic endorses keep-warm —
it means we found no rule it breaks, and built it to stay far from the
behavior Anthropic has acted against.

## Coming back cold: `/compact`, `/clear`, or neither?

A `COLD(ttl?)` on a big context is a fork in the road. The cache is gone;
whatever you do next, that context gets processed once more at the expensive
uncached rate. The only question is what that one unavoidable pass buys you:

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

## What we measured (not modeled)

Every claim above is checkable against real transcripts — Claude Code records
`cache_read_input_tokens` and `cache_creation_input_tokens` for every API turn,
and `warmline-audit` grades them. From a real 13-hour orchestration session
(2026-08-18, ~300k context, merge-queue babysitting with background CI watchers):

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
  re-wrote all 45,033 tokens. Warm at 50, cold at 70 — the 1-hour TTL is real, and
  the keep-warm ping interval (~50 minutes) sits safely inside it.
- The cold arm also demonstrated *why* pinging works: **reads refresh the TTL**.
  Its probe still found the shared system block warm, because the other arm had
  read that block 20 minutes earlier. A keep-warm ping is exactly that refresh,
  applied to your whole prefix.
- Across this machine's full history (145 sessions over 8 weeks),
  `warmline-audit --all` puts the total estimated avoidable premium at **~$66**
  at Sonnet base pricing — and attributes 43 cache rebuilds to compaction but
  **89 to unexplained prefix drift**. The leak is rarely where you expect it.
- An earlier, deliberately-dirty run of the same experiment surfaced a subtler
  failure mode: a headless `--resume` regenerates the whole system prompt, so
  git-status drift, MCP server availability, or an edited CLAUDE.md between turns
  silently diverges the prefix — and everything past the divergence re-caches at
  full price. **Prefix stability matters as much as TTL**: no keep-warm ping can
  help a session whose prefix churns between turns.

## Configuration

| Environment variable | Default | Meaning |
|---|---|---|
| `WARMLINE_TTL_MIN` | `60` | prompt-cache TTL in minutes (set `5` for short-TTL setups) |
| `WARMLINE_STATE_DIR` | `~/.claude/warmline-state` | stamp/state directory |
| `WARMLINE_BIN_DIR` | `~/.local/bin` | where the installer puts the `warmline` and `warmline-audit` commands |
| `WARMLINE_NO_COLOR` | unset | if set (or `NO_COLOR`), plain output without ANSI colors |
| `WARMLINE_FORCE_COLOR` | unset | if set, colored audit output even when piped |
| `WARMLINE_DEBUG` | unset | if set, keeps the last raw statusline payload for inspection |

Set these in the environment Claude Code starts from, or in the `env` block of
`~/.claude/settings.json`. `WARMLINE_TTL_MIN` is honored by both the statusline
and `warmline-audit`.

## Compatibility and updating

Verified against Claude Code **2.1.233** (current at the time of writing). The
statusline's JSON fields were checked against real harness payloads, and
`warmline-audit` parses every transcript format present on this machine —
Claude Code versions **2.1.181 through 2.1.233**, 145 sessions, zero malformed
entries. One known format quirk is handled: some versions omit `requestId` on
~28% of assistant entries, so the audit dedupes API requests by `message.id`.

**Updating:** the installer is the updater. Re-run the same `curl | bash`
one-liner (or `./install.sh` from a pulled checkout) — it recognizes its own
statusline and replaces it, the `warmline` command, and the auditor in place
without `--force`; your `settings.json` is backed up on every run, and your
keep-warm on/off choice is left as it was.
[CHANGELOG.md](CHANGELOG.md) tracks tagged releases.

**Windows:** the statusline and the auditor are pure standard-library Python and
don't care about the OS; only the installer and the test suite are bash. Manual
install:

1. copy `statusline.py` to `%USERPROFILE%\.claude\warmline-statusline.py`
   (and, optionally, `warmline-audit` anywhere convenient)
2. in `%USERPROFILE%\.claude\settings.json`, set
   `"statusLine": {"type": "command", "command": "python C:\\Users\\you\\.claude\\warmline-statusline.py"}`
3. run the auditor as `python warmline-audit [args]`

The `warmline` command is bash too, so on Windows toggle keep-warm by hand —
add or remove the marker-delimited block (the text is
[`keep-warm.md`](keep-warm.md)) in `%USERPROFILE%\.claude\CLAUDE.md` — or use
WSL / Git Bash. ANSI colors render fine in Windows Terminal. A tested `install.ps1` would be a
welcome contribution — in keeping with this project's philosophy, we don't ship
one we can't test.

## Tests

```sh
./test.sh
```

Replays representative statusline payloads (hot, cold-rebuild, TTL-expired,
sparse, garbage, concurrent-session isolation, idle repaints not resetting the
clock, a fresh turn overriding the TTL inference, the expiry countdown, ANSI
colors) against the script; a synthetic transcript against `warmline-audit`
including the `--price` estimate, every cold-cause attribution, and TTY vs
piped formatting; a synthetic multi-project corpus against `--all`; and the
`warmline` CLI's keep-warm state transitions (on→on, off→off, malformed
blocks reported truthfully instead of a false ON), with unrelated CLAUDE.md
content verified to survive every operation and a clean-install check that
the `warmline` command actually lands. The same suite runs in CI on every
push.

## License

[MIT](LICENSE)

## Buy me a coffee ☕

BTC: `bc1qjsvtd3dd44llyu4rwz2ucl4kp9wd9kvpsj6tk5`
