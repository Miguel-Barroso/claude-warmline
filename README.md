# claude-warmline

**English** | [日本語](README.ja.md) | [繁體中文](README.zh-TW.md) | [简体中文](README.zh-CN.md)

[![tests](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml/badge.svg)](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml)
[![version](https://img.shields.io/github/v/tag/Miguel-Barroso/claude-warmline?label=version)](https://github.com/Miguel-Barroso/claude-warmline/tags)
[![license](https://img.shields.io/github/license/Miguel-Barroso/claude-warmline)](LICENSE)

**Warmline makes Claude Code's prompt-cache state visible.**

## Claude Code can silently go cold

A working session carries tens or hundreds of thousands of tokens — system
prompt, tools, every file it read, every reply — and Claude Code re-sends all of
it on every turn. While the prompt cache holds, that context is *read back* at
roughly **0.1×** the normal input price. When the cache goes cold, the same
context is processed again at about **2×**. It goes cold after about an hour of
inactivity, and instantly whenever the start of the conversation is rewritten —
`/compact` and auto-compaction both do that. Come back to a big session after
lunch and your next message pays the rebuild on all of it, at exactly the moment
you wanted results, and nothing in the session tells you so.

**Warmline puts the cache state directly in your statusline, and gives you the
tools to see what it has been doing historically.**

```text
Opus 5 | claude-warmline | ctx 64% (127k) | cache HOT (127k, cold ~11:58) | 5h 78%
```

No guessing, and no timing-based inference. Since v2.1.251 Claude Code hands
the statusline its own `prompt_cache` object — whether the prefix is warm, which
TTL it is on, the second it expires — and warmline prints what that object says.

Then, for everything before this turn:

```text
warmline audit
```

grades every recorded API turn of a session from the usage Claude Code wrote for
it, and `--all` ranks every session on this machine.

![The warmline statusline in five states: cache HOT in green with its expiry time, cache HOT in yellow as the expiry nears, cache COLD in red, and cache off and cache ? dimmed when Claude Code reports no cache data](docs/statusline.svg)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash
```

or with Homebrew, on macOS:

```sh
brew install Miguel-Barroso/warmline/warmline
```

Then:

| Command | What it does |
|---|---|
| `warmline status` | what's installed and on |
| `warmline audit` | this project's latest session, turn by turn |
| `warmline audit --all` | every session on this machine, ranked |
| `warmline watch` | every session's warmth, live, until ctrl-c |

Needs `python3` and `bash`, nothing else. No `curl`? `wget -qO- <same URL> | bash`
works the same way, and the installer downloads with whichever one it finds.
Whichever route you take it is one command: `brew install` wires the statusline
too, `brew upgrade` re-wires it, and `brew uninstall` unwires it again.

[Install details, flags, pinning a release, package managers, Windows →](docs/INSTALL.md)

## Why warmline

Most Claude Code statuslines answer questions like:

- Which model am I on?
- How much context is left?
- What is this session costing?
- Which branch am I on?

All useful. Warmline answers a different one:

> **Is the prompt cache actually warm?**

and then the one no live indicator can answer:

> **When did it go cold, how often, and did that cost enough to care about?**

A statusline tells you what is happening in your session. **Warmline tells you
whether your context is still being reused.**

Everything here exists for the 100k+ case. Going cold on 20k tokens is cheap.

## From visibility to control

**Observe** — the cache state in your statusline, live, from Claude Code's own
data.

**Explain** — what `HOT`, `COLD`, `off` and the expiry clock each mean, and
which of them you can do anything about.

**Measure** — `warmline audit`: the cold events across your history, what
caused them where the transcript proves a cause, and an estimate of what they
were worth.

**Mitigate** — `warmline keep-warm`, if it turns out you need it.

That is a progression, not a feature list. It takes you from *"did my cache go
cold?"* to *"how often does this happen?"* to *"is it costing me enough to
care?"* to *"do I want to do something about it?"* — and the honest answer to
the last one is often no.

The first three are read-only observation, and they are the point of the
project. The fourth is opt-in, off by default, and deliberately bounded — see
[optional: keep warm](#optional-keep-warm).

## Observe: the statusline

```
Opus 5 | claude-warmline | ctx 64% (127k) | cache HOT (127k, cold ~11:58) | 5h 78%
```

| Field | Meaning |
|---|---|
| `ctx 64% (127k)` | context-window utilization — yellow within 10k tokens of the threshold auto-compaction actually fires at (`window - 33000`) |
| `cache HOT (127k, cold ~11:58)` | the cached prefix is warm, a rebuild would re-cache 127k tokens, and it leaves its TTL at the time shown; yellow within 15 minutes of it |
| `cache HOT 5m` | as above, on the 5-minute TTL — usage credits, an API key, a cloud provider. The 1-hour case is the norm and goes unlabelled |
| `5h 78%` / `7d 91%` | the plan window nearest its cap, hidden below 50%, with its reset time once it turns yellow. Absent on API keys and cloud providers, which have no plan window |
| `cache COLD` | the prefix is outside its TTL; the next turn re-caches it |
| `cache off` | prompt caching is off, or this provider or gateway never reports cache tokens. Nothing here will warm up |
| `cache ?` | no cache data — Claude Code before v2.1.251, or before the session's first API response |

**Warmline does not try to work out whether your cache is warm by timing how
long Claude Code takes to answer.** Every verdict above is a field Claude Code
handed the statusline: `prompt_cache.warm` for the state, `caching_observed` for
whether caching is happening at all, `ttl` for the bucket, `expires_at` for the
clock, `recache_tokens_if_cold` for the stake, `rate_limits` for the plan
window. Warmline formats and colors them. It used to infer all of this from the
gap between turns, and that machinery is gone.

The two numbers that decide anything are the stake and the quota. **`(127k)` is
what a rebuild would cost you** — the size of the next cache write if this
prefix goes cold, which is what makes "worth keeping warm" a number rather than
a feeling. **`5h 78%`** is the currency a subscription actually runs out of:
plan windows, not dollars, are what stop work mid-task.

`COLD`, `off` and `?` are kept distinct on purpose: "the cache expired",
"caching isn't happening here" and "warmline can't see" are three different
facts, and collapsing them is how a cache gauge starts lying.

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

A single `HOT` on your statusline is useful. Seeing that your sessions went cold
198 times in eight weeks is more useful.

`warmline audit` grades every recorded API request of a session from the usage
fields Claude Code wrote for it — no one-turn lag, unlike the statusline. `--all`
does the same across every session on this machine and ranks them. (It runs the
installed `warmline-audit`; both spellings work, and scripts pinned to the
hyphenated one keep working.) Real output from 8 weeks of history, priced at a
flat `--price 3` for a stable example — a bare `--price` solves your real rate
instead, per project:

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

That is the difference between observability and a decorative statusline: a
pattern you can act on, or decide not to.

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
such as a TTL expiry while the laptop was asleep.

**Warmline ships no price sheet.** A baked-in table would go stale, and it
would be wrong the moment you switched from Sonnet to Opus. A bare `--price`
solves for the base input rate you are actually paying, from the cost Claude
Code recorded for your last session in that project, using the multiples every
Claude pricing tier shares (output 5× base input, a 1-hour cache write 2×, a
5-minute write 1.25×, a warm read 0.1×). `--all` prices each project at its own
solved rate, every report prints where the number came from, and `--price N`
still overrides. Output tokens are never cached, so the audit prices them on
their own line rather than pretending warmth could save them.

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
for free, when the stake is small, and on the 5-minute cache, where ~12 pings an
hour would cost more than the 1.15× rebuild they prevent. It stops the moment
work resumes, and gives up after ~10 hours. Each ping is an ordinary billed
request against your own plan: it trades one expensive rebuild for a few cheap
reads, and bypasses nothing.

Better still, when the wait is something this machine can watch, don't schedule
a ping at all:

```sh
warmline wait-for --pidfile /tmp/job.pid --until-cold
```

returns when the job ends **or** just before the cache expires, whichever comes
first — read from this session's own transcript, so a job that finishes at
minute 12 costs no ping at all.

[What it is and isn't, `wait-for`, no-sleep mode, limits, terms →](docs/KEEP-WARM.md)

## Local by design

Warmline runs on your machine. It does not phone home, collect telemetry, or
require an account, and it has no dependencies beyond `python3` and `bash`.

Everything it shows comes from data Claude Code already produced locally: the
JSON payload Claude Code pipes to the statusline, and the session transcripts
under `~/.claude/projects`. **Warmline observes what Claude Code exposes
locally** — it has no special access to anything of Anthropic's, and there is
nothing to log into.

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
