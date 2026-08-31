# claude-warmline

**English** | [日本語](README.ja.md) | [繁體中文](README.zh-TW.md) | [简体中文](README.zh-CN.md)

[![tests](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml/badge.svg)](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml)
[![version](https://img.shields.io/github/v/tag/Miguel-Barroso/claude-warmline?label=version)](https://github.com/Miguel-Barroso/claude-warmline/tags)
[![license](https://img.shields.io/github/license/Miguel-Barroso/claude-warmline)](LICENSE)

**See when Claude Code quietly re-processes your entire conversation — and prevent the avoidable part.**

Lightweight observability for Claude Code's hidden context/cache economics: a
statusline, an auditor, and an optional keep-warm policy. No dependencies
beyond `python3` and `bash`; nothing phones home — everything is read from data
Claude Code already records on your machine.

![The warmline statusline in its three states: cache HOT in green with keep-warm on, cache COLD(rebuilt) in yellow, cache COLD(ttl?) in red with keep-warm off](docs/statusline.svg)

## The 30-second version

Claude doesn't remember anything between messages. Every time you press enter,
Claude Code re-sends the *entire* conversation so far — system prompt, tools,
every file it read, every reply. On a long session that's easily 100k+ tokens
of input, every single turn.

What makes this affordable is a server-side **prompt cache**. Think of it as a
workspace Claude has already set up for your conversation: while the workspace
stands, each new message *reads* it at roughly **0.1×** the normal input price.
Setting it up costs about **2×** — paid once, then amortized over every turn.

The catch: the workspace is quietly torn down after **about an hour of
inactivity**, and instantly whenever the start of the conversation is rewritten
(`/compact` always triggers a full rebuild). Come back to a big session after
lunch and your next message pays 2× on all of it, at exactly the moment you
wanted results.

Claude Code doesn't surface any of this. warmline makes it visible — and helps
prevent the part that's avoidable.

## Quick start

```sh
curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash

warmline status              # what's installed and on
warmline keep-warm on        # optional: prevent avoidable cold starts
```

Then use Claude Code normally — the statusline shows the cache state live.
When you want to know what a session (or all of them) actually cost:

```sh
warmline-audit               # this session, turn by turn
warmline-audit --all         # every session, ranked by where the money leaked
warmline watch               # every session's warmth, live, until ctrl-c
```

[Install details, flags, updating, Windows →](docs/INSTALL.md)

## Reading the line

```
Fable 5 | claude-warmline | ctx 43% (168k) | cache HOT (cold ~13:04) | gap 12m | keep-warm on
```

| Field | Meaning |
|---|---|
| `ctx 43% (168k)` | context-window utilization and input tokens in the conversation — yellow past 80%, where auto-compaction starts rewriting the prefix |
| `cache HOT (cold ~13:04)` | the previous request read from the prompt cache; the cache expires at the time shown (green) |
| `cache HOT (cold in 9m)` | still warm, but within 15 minutes of the TTL — act now or pay the rebuild (yellow) |
| `cache COLD(rebuilt)` | the previous request found the prefix cold and re-cached it (yellow) |
| `cache COLD(ttl?)` | *inferred*: quiet for longer than the TTL, so the cache has expired (red) |
| `gap 12m` | minutes since this session's last API turn; idle repaints don't reset it |
| `keep-warm on` | the [keep-warm policy](#keep-warm) is installed and current — `on*` if an upgrade left your CLAUDE.md block behind, `off` dim, `?` if the block is malformed |

The line can't go stale: the installer wires `refreshInterval: 60`, so Claude
Code re-runs the gauge every minute even while the session just sits there —
the countdown ticks, and `COLD(ttl?)` takes over within a minute of expiry
instead of a green `HOT` frozen on screen all evening. (That refresh is a
local repaint; it never touches the API and doesn't keep the cache warm.) Two
honest caveats remain: the usage numbers describe the *previous* request, so
`HOT`/`COLD(rebuilt)` lag one turn, and `COLD(ttl?)` is a time-based
inference — hence the `?`.

[Every field, colors, the gap mechanics, troubleshooting →](docs/STATUSLINE.md)

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

## Where the money went

`warmline-audit` grades every recorded API request of a session — no lag, no
inference — and `--all` ranks every session on the machine by **avoidable cold
tokens**: everything re-cached cold *after* the first write a session can't
avoid. Real output from one machine's 8 weeks of history:

```
$ warmline-audit --all --price 3
147 sessions under /Users/mb/.claude/projects  (13 more without API turns; ttl per session from its cache buckets, 60m fallback)

cache health  █████████████████████████░  95% hot  (10,394 of 10,921 turns)
cold events   198  (159 rebuilt, 39 ttl) -- 1.8% of all turns

start        project                 turns    hot  part  rebuilt   ttl  avoidable cold  share    premium
08-07 14:30  MimirBlue                 201    189     6        4     2       1,294,770    11%      $7.38
   ⋮
TOTAL                                10921  10394   329      159    39      12,134,109   100%     $69.16

where the cold came from
  unknown             ██████████████████████████  92 (39%)
  session start       █████████████████  59 (25%)
  auto-compact        ██████████  37 (16%)
  inactivity          █████████  31 (13%)

estimated avoidable premium ~$69.16  (top 5 sessions: $21.36, other 142: $47.81)
```

Each cold turn carries a cause where the transcript proves one — `/compact`,
`auto-compact`, `model change`, `inactivity` — and an honest `unknown` where it
doesn't (in practice, prefix drift: an edited CLAUDE.md, changed git state, MCP
availability). The percentages make the ranking immediate: on this machine,
silent drift caused 39% of the cold — more than all compaction combined — and
the worst single session holds 11% of the entire leak. The leak is rarely
where you expect it.

The premium is an estimate computed from token counts in your own transcripts,
never billing data — and it prices input and output tokens separately, because
Claude does: `--price` is your model's base **input** $/MTok (all cache
economics live on that side), `--price-out` your **output** $/MTok, defaulting
to 5× input as on the current price sheet. Output tokens are never cached, so
the audit reports them on their own line rather than pretending warmth could
save them.

And where the audit grades the past, **`warmline watch`** shows the present: a
live view of every session's warmth — which prefixes the cache still holds,
and when each goes cold — re-rendered every 10 seconds. Sessions from the
desktop app appear too; they write the same transcripts even though they can't
render a statusline.

[Full walkthrough, verdicts, causes, `--all`, `--live`, `--json` →](docs/AUDIT.md)

## Keep Warm

Everything above *observes*. Keep Warm is the optional half that *prevents*: a
short instruction block in your `~/.claude/CLAUDE.md` telling the agent to ping
a long, quiet wait about every 50 minutes, so the cache is still warm when the
results land.

```sh
warmline keep-warm on        # global, persists across sessions and updates
warmline keep-warm status    # ON / OFF / INCONSISTENT (exit 0 / 1 / 2)
warmline keep-warm off
warmline awake               # no-sleep mode: one claude session with system
                             # sleep held off; normal sleep returns on /exit
warmline wait-for --pid N    # wake the session when a detached job ends
```

It is **not a daemon** — no cron, no process, nothing outside a running Claude
Code session. It skips when background tasks are already keeping the cache warm
for free, skips small contexts, stops the moment work resumes, and gives up
after ~10 hours. A ping costs ~0.1× your context; the rebuild it prevents costs
~2×. The policy names no particular scheduler, only the requirement — something
must re-enter the session inside one TTL, and must be removable — because
builds differ in what they offer.

When the wait is on *this* machine, a timed ping is the wrong tool.
`warmline wait-for` is a poller you run as a background task: it wakes the
session when the job ends **or fails**, needs no schedule, and terminates
itself. Pings are for waits nothing local can watch.

The one thing no ping survives is a sleeping machine. For a wait you intend to
sit out, `warmline awake` starts your `claude` session with system sleep
inhibited — and because the inhibition lives exactly as long as the session,
the OS restores normal sleep the instant you `/exit` (or crash out). Nothing
to remember to turn off.

[What it is and isn't, when it can't operate, terms →](docs/KEEP-WARM.md)

## Where it works

| Front end | statusline | `warmline-audit` / `watch` | keep-warm |
|---|---|---|---|
| Terminal CLI | ✅ | ✅ | ✅ |
| Desktop app (local Code tab) | ❌ | ✅ | ✅ |
| VS Code / JetBrains panel | ❌ | ✅ | ✅ |
| Cloud / Cowork sessions | ❌ | ❌ | ❌ |

The desktop app and the IDE panels don't render custom statuslines
([open request](https://github.com/anthropics/claude-code/issues/41456)) — but
they run the same engine *locally*, share the same `~/.claude`, and write the
same transcripts, so the auditor, the live `warmline watch` view, and the
keep-warm policy work there unchanged. **Cloud and Cowork sessions are the
exception: no part of warmline reaches them.** They run on Anthropic's
infrastructure, leave no transcripts on your machine, and never read your
local `~/.claude/CLAUDE.md`. In the desktop app, run `claude` in the
integrated terminal when you want the gauge too.

[The full surface matrix, and how it was verified →](docs/SURFACES.md)

## Measured, not modeled

- **96% hot across a 4.5-hour supervised wait, 0 tokens re-cached cold** — the
  policy on, 187 turns, 16.1M tokens read from cache. Every warmth break was an
  *auto*-compaction, none a TTL expiry.
- **Auto-compact fires around 84% of the window** (three times, at 167–169k of
  200k). That is the one cache killer keep-warm cannot prevent — only warn
  about, which is why `ctx` goes yellow at 80%.
- **50 minutes idle: warm. 70 minutes: cold.** A clean-room two-arm probe read
  a full 71,312-token prefix back after 50 minutes and re-wrote 45,033 tokens
  after 70. The 1-hour TTL is real, and reads refresh it — which is exactly why
  pinging works.
- **Background work keeps the cache warm for free.** Task notifications every
  ~9 minutes held a 300k context hot for four hours at ~400 tokens of
  cache-write per wake. That's why keep-warm skips that case.
- **No wakeup survives a closed lid.** The one TTL expiry in a 260-turn,
  13-hour session came after a 6-hour overnight silence with the machine
  asleep. (`warmline awake` exists for exactly this.)
- **Prefix stability matters as much as TTL.** A drifting system prompt
  (edited CLAUDE.md, changed git state, MCP availability) re-caches everything
  past the divergence, and no ping can help.

[Numbers, method, how to reproduce →](docs/MEASUREMENTS.md)

## Docs

| | |
|---|---|
| [Statusline](docs/STATUSLINE.md) | every field, colors, gap mechanics, troubleshooting |
| [Audit](docs/AUDIT.md) | verdicts, cause attribution, `--all`, the live `watch` view, what "avoidable" means |
| [Keep Warm](docs/KEEP-WARM.md) | the policy, no-sleep mode (`warmline awake`), limits, the terms question |
| [Where it works](docs/SURFACES.md) | terminal, desktop, IDE, SSH, cloud |
| [Install](docs/INSTALL.md) | install, update, uninstall, configure, Windows, tests |
| [Measurements](docs/MEASUREMENTS.md) | the evidence behind every claim |
| [Changelog](CHANGELOG.md) | tagged releases |

## License

[MIT](LICENSE)

## Buy me a coffee ☕

BTC: `bc1qjsvtd3dd44llyu4rwz2ucl4kp9wd9kvpsj6tk5`
