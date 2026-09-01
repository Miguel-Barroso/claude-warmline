# claude-warmline

**English** | [日本語](README.ja.md) | [繁體中文](README.zh-TW.md) | [简体中文](README.zh-CN.md)

[![tests](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml/badge.svg)](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml)
[![version](https://img.shields.io/github/v/tag/Miguel-Barroso/claude-warmline?label=version)](https://github.com/Miguel-Barroso/claude-warmline/tags)
[![license](https://img.shields.io/github/license/Miguel-Barroso/claude-warmline)](LICENSE)

**Prompt-cache observability and auditing for Claude Code.**

Claude Code re-sends your entire conversation on every turn. A server-side
prompt cache is what makes that affordable: while it holds, each turn *reads*
the conversation back at roughly **0.1×** the normal input price; once it's
gone, the next turn re-creates it at about **2×**. Claude Code knows all of
this and will tell you when asked — `/usage` prints the live cache state, and
since v2.1.251 the statusline payload carries it. What it doesn't do is keep
it in front of you, or tell you what going cold has cost you across last
month's sessions. warmline does both: it puts Claude Code's own cache truth on
the status line, and audits the history locally, from data Claude Code already
records on your machine, with no dependencies beyond `python3` and `bash`, and
nothing phones home.

![The warmline statusline in five states: cache HOT in green with its expiry time, cache HOT in yellow as the expiry nears, cache COLD in red, and cache off and cache ? dimmed when Claude Code reports no cache data](docs/statusline.svg)

## What it does

**Observe → Explain → Measure → Mitigate.**

| | | |
|---|---|---|
| **Observe** | the `warmline` statusline | what the cache is doing right now |
| **Explain** | `warmline audit` | what happened in one session, turn by turn |
| **Measure** | `warmline audit --all` | where the exposure is across every session on this machine |
| **Mitigate** | `warmline keep-warm` | *optional*: prevent one preventable failure mode |

The first three are read-only observation, and they are the point of the
project. The fourth is opt-in, off by default, and deliberately bounded — see
[optional: keep warm](#optional-keep-warm).

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash

warmline status              # what's installed and on
warmline audit               # this project's latest session, turn by turn
warmline audit --all         # every session on this machine, ranked
warmline watch               # every session's warmth, live, until ctrl-c
```

[Install details, flags, updating, Windows →](docs/INSTALL.md)

## Why it matters

What gets re-sent is the *entire* conversation — system prompt, tools, every
file it read, every reply — easily 100k+ input tokens on a long session, every
single turn. The cache absorbs that, but it is torn down after **about an hour
of inactivity**, and instantly whenever the start of the conversation is
rewritten (`/compact` and auto-compaction both do this). Come back to a big
session after lunch and your next message pays the rebuild on all of it, at
exactly the moment you wanted results.

Everything here exists for the 100k+ case. Going cold on 20k tokens is cheap.

## Observe: the statusline

```
Fable 5 | claude-warmline | ctx 43% (168k) | cache HOT (cold ~13:04)
```

| Field | Meaning |
|---|---|
| `ctx 43% (168k)` | context-window utilization — yellow past 80%, where auto-compaction starts rewriting the prefix |
| `cache HOT (cold ~13:04)` | the cached prefix is warm and leaves its TTL at the time shown; yellow within 15 minutes of it |
| `cache HOT 5m` | as above, on the 5-minute TTL — usage credits, an API key, a cloud provider. The 1-hour case is the norm and goes unlabelled |
| `cache COLD` | the prefix is outside its TTL; the next turn re-caches it |
| `cache off` | prompt caching is off, or this provider or gateway never reports cache tokens. Nothing here will warm up |
| `cache ?` | no cache data — Claude Code before v2.1.251, or before the session's first API response |

**Every one of these comes from Claude Code, not from warmline.** Since
v2.1.251 the statusline payload carries the cache's real warmth, TTL and
expiry timestamp, so warmline reads them instead of timing the gap between
turns and guessing. `COLD`, `off` and `?` are kept distinct on purpose: "the
cache expired", "caching isn't happening" and "warmline can't see" are three
different facts, and collapsing them is how a cache gauge starts lying.

The expiry is absolute wall-clock, never a countdown — a frozen countdown is
wrong, while a frozen clock is still true.

[Every field, colors, troubleshooting →](docs/STATUSLINE.md)

### When you come back cold

The cache is gone; that context gets processed once more at the uncached rate
whatever you do next. The only question is what that one pass buys:

- **You still need the conversation history →** `/compact`. The expensive pass
  was coming anyway; this way it produces a summary you carry cheaply from then on.
- **Your state is written down outside the conversation** (memory files, a plan
  document, the code) **→** `/clear`. It skips even the summarization pass.
- **Small context →** do nothing. Rebuilding 20k tokens is cheap.
- **Never while `HOT`**, unless you are out of context window: compacting
  destroys a cache you already paid ~2× to build.

[The full reasoning →](docs/AUDIT.md#when-you-come-back-cold)

## Explain and measure: the audit

`warmline audit` grades every recorded API request of a session from the usage
fields Claude Code wrote for it — no one-turn lag, unlike the statusline. `--all`
does the same across every session on this machine and ranks them. (It runs the
installed `warmline-audit`; both spellings work, and scripts pinned to the
hyphenated one keep working.) Real output from 8 weeks of history:

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

Each cold turn carries a cause where the transcript **proves** one — `/compact`,
`auto-compact`, `model change`, `inactivity`. Everything else lands in
`unknown`, which is a **residual bucket, not a finding**: the transcript
recorded no proof, so warmline declines to name a cause. Anthropic documents
several prefix-invalidating actions a transcript never witnesses — changing the
effort level, turning on fast mode, denying a whole tool, enabling or disabling
a plugin, connecting an MCP server whose tools load into the prefix, and
upgrading Claude Code itself — and any of them lands here. Editing CLAUDE.md
mid-session does not: Anthropic lists that under the actions that *keep* the
cache. Here `unknown` holds 39% of the cold, more than all compaction combined,
and the worst single session holds 11% of the total — read that as "the largest
share is unexplained", which is a reason to look, not a diagnosis.
(Verdicts come from recorded usage, but the
split between `COLD(rebuilt)` and `COLD(ttl)` rests on the TTL, auto-detected
per session from its own cache-bucket records.)

**The dollar figures estimate exposure from token counts in your own
transcripts. They are not billing data** — warmline never sees, and cannot see,
what Anthropic actually billed you. The closing line is labeled `estimated
avoidable premium`, where "avoidable" means only *after each session's
unavoidable first cache write*: some of what it counts was never preventable,
such as a TTL expiry while the laptop was asleep. `--price` is your model's base
**input** $/MTok, where all cache economics live; output tokens are never cached,
so the audit prices them on their own line rather than pretending warmth could
save them.

Where the audit grades the past, **`warmline watch`** shows the present: every
session's warmth, live, until ctrl-c. Desktop-app sessions appear too — they
write the same transcripts even though they can't render a statusline.

[Full walkthrough, verdicts, causes, `--all`, `--live`, `--json` →](docs/AUDIT.md)

## Optional: keep warm

Everything above observes. Keep Warm is the optional fourth capability: a short
instruction block in your `~/.claude/CLAUDE.md` telling the agent to ping a long,
quiet wait about every 50 minutes, so the cache is still warm when results land.

```sh
warmline keep-warm on        # off by default; global; reversible
warmline keep-warm status    # ON / OFF / INCONSISTENT (exit 0 / 1 / 2)
```

It is **not a daemon** — no cron, no process, nothing outside a running Claude
Code session. It skips when background tasks are already keeping the cache warm
for free, skips small contexts, stops the moment work resumes, and gives up
after ~10 hours. Each ping is an ordinary billed request against your own plan:
it trades one expensive rebuild for a few cheap reads, and bypasses nothing.

[What it is and isn't, `wait-for`, no-sleep mode, limits, terms →](docs/KEEP-WARM.md)

## Where it works

| Front end | statusline | `warmline audit` / `watch` | keep-warm |
|---|---|---|---|
| Terminal CLI | ✅ | ✅ | ✅ |
| Desktop app (local Code tab) | ❌ | ✅ | ✅ |
| VS Code / JetBrains panel | ❌ | ✅ | ✅ |
| Cloud / Cowork sessions | ❌ | ❌ | ❌ |

The local graphical front ends don't render custom statuslines
([open request](https://github.com/anthropics/claude-code/issues/41456)), but they
run the same engine, share the same `~/.claude` and write the same transcripts, so
the audit, `warmline watch` and keep-warm work there unchanged. **Cloud and Cowork
sessions are the exception: no part of warmline reaches them.**

[The full surface matrix, and how it was verified →](docs/SURFACES.md)

## Evidence

The TTL is measured, not assumed. In a clean-room two-arm probe, a session idle
**50 minutes** read its full 71,312-token prefix back from cache; an identical
one idle **70 minutes** found the cache gone and re-wrote all 45,033 tokens.
Warm at 50, cold at 70 — and reads refresh the clock. Everything else on this
page comes from the same corpus the audit above grades.

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
