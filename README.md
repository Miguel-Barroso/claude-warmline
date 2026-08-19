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
```

[Install details, flags, updating, Windows →](docs/INSTALL.md)

## Reading the line

```
Fable 5 | claude-warmline | ctx 43% (168k) | cache HOT | gap 12m | keep-warm on
```

| Field | Meaning |
|---|---|
| `ctx 43% (168k)` | context-window utilization and input tokens in the conversation |
| `cache HOT` | the previous request read from the prompt cache (green) |
| `cache HOT (cold in 9m)` | still warm, but within 15 minutes of the TTL — act now or pay the rebuild (yellow) |
| `cache COLD(rebuilt)` | the previous request found the prefix cold and re-cached it (yellow) |
| `cache COLD(ttl?)` | *inferred*: quiet for longer than the TTL, so the cache has expired (red) |
| `gap 12m` | minutes since this session's last API turn; idle repaints don't reset it |
| `keep-warm on` | whether the [keep-warm policy](#keep-warm) is installed — `off` dim, `?` if the block is malformed |

Two honest caveats: Claude Code hands the statusline the usage numbers of the
*previous* request, so `HOT`/`COLD(rebuilt)` lag one turn, and `COLD(ttl?)` is a
time-based inference — hence the `?`. What warmline guarantees is that the idle
clock survives repaints, so the first repaint after you return already reads
`COLD(ttl?)`, before you've spent anything.

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
145 sessions under /Users/mb/.claude/projects  (13 more without API turns; ttl 60m)

cache health  █████████████████████████░  95% hot  (10,242 of 10,756 turns)
cold events   187  (152 rebuilt, 35 ttl)

start        project                 turns    hot  part  rebuilt   ttl  avoidable cold    premium
08-07 14:30  MimirBlue                 201    189     6        4     2       1,294,770      $7.38
   ⋮
TOTAL                                10756  10242   327      152    35      11,661,736     $66.47

where the cold came from
  unknown             ██████████████████████████  89
  session start       ████████████████  56
  auto-compact        ███████████  36
  inactivity          ████████  28

estimated avoidable premium ~$66.47  (top 5 sessions: $21.36, other 140: $45.12)
```

Each cold turn carries a cause where the transcript proves one — `/compact`,
`auto-compact`, `model change`, `inactivity` — and an honest `unknown` where it
doesn't (in practice, prefix drift: an edited CLAUDE.md, changed git state, MCP
availability). Note what that means here: silent drift rebuilt more caches than
compaction did. The leak is rarely where you expect it.

The premium is an estimate computed from token counts in your own transcripts,
never billing data.

[Full walkthrough, verdicts, causes, `--all`, `--json` →](docs/AUDIT.md)

## Keep Warm

Everything above *observes*. Keep Warm is the optional half that *prevents*: a
short instruction block in your `~/.claude/CLAUDE.md` telling the agent to ping
a long, quiet wait about every 50 minutes, so the cache is still warm when the
results land.

```sh
warmline keep-warm on        # global, persists across sessions and updates
warmline keep-warm status    # ON / OFF / INCONSISTENT (exit 0 / 1 / 2)
warmline keep-warm off
```

It is **not a daemon** — no cron, no process, nothing outside a running Claude
Code session. It skips when background tasks are already keeping the cache warm
for free, skips small contexts, stops the moment work resumes, and gives up
after ~10 hours. A ping costs ~0.1× your context; the rebuild it prevents costs
~2×.

[What it is and isn't, when it can't operate, terms →](docs/KEEP-WARM.md)

## Where it works

| Front end | statusline | `warmline-audit` | keep-warm |
|---|---|---|---|
| Terminal CLI | ✅ | ✅ | ✅ |
| Desktop app (local Code tab) | ❌ | ✅ | ✅ |
| VS Code / JetBrains panel | ❌ | ✅ | ✅ |
| Cloud / Cowork sessions | ❌ | ❌ | — |

Graphical front ends don't render custom statuslines
([open request](https://github.com/anthropics/claude-code/issues/41456)) — but
they run the same engine, share the same `~/.claude`, and write the same
transcripts, so the auditor and the keep-warm policy work there unchanged. In
the desktop app, run `claude` in the integrated terminal when you want the
gauge too.

[The full surface matrix, and how it was verified →](docs/SURFACES.md)

## Measured, not modeled

- **50 minutes idle: warm. 70 minutes: cold.** A clean-room two-arm probe read
  a full 71,312-token prefix back after 50 minutes and re-wrote 45,033 tokens
  after 70. The 1-hour TTL is real, and reads refresh it — which is exactly why
  pinging works.
- **Background work keeps the cache warm for free.** Task notifications every
  ~9 minutes held a 300k context hot for four hours at ~400 tokens of
  cache-write per wake. That's why keep-warm skips that case.
- **No wakeup survives a closed lid.** The one TTL expiry in a 260-turn,
  13-hour session came after a 6-hour overnight silence with the machine
  asleep.
- **Prefix stability matters as much as TTL.** A drifting system prompt
  (edited CLAUDE.md, changed git state, MCP availability) re-caches everything
  past the divergence, and no ping can help.

[Numbers, method, how to reproduce →](docs/MEASUREMENTS.md)

## Docs

| | |
|---|---|
| [Statusline](docs/STATUSLINE.md) | every field, colors, gap mechanics, troubleshooting |
| [Audit](docs/AUDIT.md) | verdicts, cause attribution, `--all`, what "avoidable" means |
| [Keep Warm](docs/KEEP-WARM.md) | the policy, its limits, and the terms question |
| [Where it works](docs/SURFACES.md) | terminal, desktop, IDE, SSH, cloud |
| [Install](docs/INSTALL.md) | install, update, uninstall, configure, Windows, tests |
| [Measurements](docs/MEASUREMENTS.md) | the evidence behind every claim |
| [Changelog](CHANGELOG.md) | tagged releases |

## License

[MIT](LICENSE)

## Buy me a coffee ☕

BTC: `bc1qjsvtd3dd44llyu4rwz2ucl4kp9wd9kvpsj6tk5`
