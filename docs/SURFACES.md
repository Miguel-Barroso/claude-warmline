# Where warmline works

[← back to the README](../README.md)

Claude Code is one engine behind several front ends. warmline is three
independent pieces, and they don't all reach every front end:

| Front end | statusline | `warmline audit` / `watch` | keep-warm policy | [AFK mode](AFK.md) (`afk`, `/afk`) |
|---|---|---|---|---|
| Terminal CLI (`claude`) | ✅ | ✅ | ✅ | ✅ |
| Desktop app — Code tab, local session | ✅ [as a band above the prompt](#the-desktop-band) | ✅ same transcripts | ✅ same CLAUDE.md | ✅ same hooks and commands |
| VS Code / JetBrains extension panel | ❌ not rendered (the band's hooks run; nothing is drawn) | ✅ | ✅ | ✅ |
| CLI inside an IDE's integrated terminal | ✅ | ✅ | ✅ | ✅ |
| Desktop app — SSH session | ❌ | ✅ *on the remote host* | ✅ *on the remote host* | ✅ *enabled on the remote host* |
| Cloud / Cowork / Dispatch sessions | ❌ | ❌ nothing local to read | ❌ local CLAUDE.md never reaches them | ❌ |

**Short version for the desktop app: all three, one of them in a different
shape.** The `statusLine` script is never rendered there, so warmline draws the
gauge as a [band above the prompt](#the-desktop-band) instead; the auditor —
including the live [`warmline watch`](AUDIT.md#which-sessions-are-warm-right-now---live--warmline-watch)
view — and keep-warm work exactly as they do in the CLI.

## Why the statusline is terminal-only

`statusLine` is rendered by the CLI's terminal UI — a row above the built-in
footer, filled with your script's stdout, ANSI and all. The graphical front
ends draw their own chrome instead: the desktop app shows the model name in
the corner, the VS Code extension uses the editor's own status bar for
progress. They share and validate the same `settings.json` schema (so a
`statusLine` entry there is legal and harmless), but nothing renders its
output. Asking for parity is an open feature request,
[anthropics/claude-code#41456](https://github.com/anthropics/claude-code/issues/41456)
(open since March 2026).

That request is still open, and warmline no longer waits on it: the next
section is how the gauge reaches the desktop app without a `statusLine`.

## The Desktop band

Since v2.8.0 warmline fills the gap itself. Claude Code can load a plugin of
*function hooks* — one TypeScript module the engine runs in-process, which
Anthropic's docs call a mod — and such a plugin may draw a band above the
prompt on the terminal and in the Desktop app's Code tab alike. warmline's is
[`plugin/`](../plugin) in this repo. Installed, it is one row:

```text
warmline  last turn PARTIAL  (wrote 31k, read 26k)  just now  · session 0 hot 1 partial 0 cold  [Hide]
```

(captured in the Desktop app's Code tab, first response of a fresh session).

What it says, and where every word comes from:

- **`last turn HOT` / `PARTIAL` / `COLD`** is the grade of the last main-thread
  API response, from the `cache_read_input_tokens` and
  `cache_creation_input_tokens` Claude Code reports for it, by the rule
  [`warmline audit`](AUDIT.md) uses: read something back and wrote no more than
  that, HOT; wrote more than it read, PARTIAL; wrote and read nothing back,
  COLD. `?` is a response with input tokens but no cache traffic. Each response
  is graded as it lands, mid-turn included; subagents' are left out, as the
  audit leaves them out.
- **`(read 127k)` / `(wrote 31k, read 26k)`** is that traffic, in the
  statusline's units.
- **`just now` / `47 min ago`** is how long since that response, refreshed
  once a minute while the session idles.
- **`session 12 hot 1 partial 2 cold`** is this session's tally, the counts
  `warmline audit` gives the session afterwards.
- **`[Hide]`** hides it for the rest of the session.

What it deliberately does not say is whether the prefix is warm *now*. The
statusline prints Claude Code's own verdict — the `prompt_cache` object with
its `warm` flag, its TTL bucket and the second it expires — and the plugin API
exposes none of that: a plugin sees each response's four token counts and
nothing about the TTL. Printing an expiry would mean assuming one, which is the
inference warmline gave up in v2.1. So the band reports two facts, the last
response's grade and its age, and leaves the hour arithmetic to you: the TTL is
[measured](MEASUREMENTS.md) at about an hour, and the statusline marks the
five-minute bucket when a session is on it. The first response of a session
usually grades PARTIAL or COLD — the system prompt and tools read back from
another session's cache, the rest written for the first time — which the audit
files under "session start", unavoidable.

Where it draws:

- **Desktop app, Code tab.** The reason it exists. Nothing shows until the
  first prompt, because Desktop starts the engine when you send it; after that
  every response updates the band. The app's bundled engine must be 2.1.286 or
  later (`/status` in a session shows it).
- **Terminal.** The same hooks run, but the band yields whenever warmline's
  `statusLine` is wired in `settings.json`: the statusline knows the TTL, the
  band does not, and one gauge is enough. Unwire the statusline and the band
  appears in the terminal too (Claude Code 2.1.287 or later).
- **VS Code / JetBrains panels.** The hooks run; the panels draw no plugin UI
  yet.
- **Cloud, Cowork, Dispatch.** Nothing: those sessions load no user plugins.

How it is installed, and the one rule:

- **`install.sh`, `brew install` and `warmline setup`** copy the four plugin
  files to `~/.claude/skills/warmline/`, which Claude Code auto-loads in every
  local session as `warmline@skills-dir` — no marketplace, no second step.
  `warmline status` shows it on the `desktop` line; uninstalling removes it.
- **A plugin marketplace** is the other channel, for the Desktop app's plugin
  browser and for anyone who never opens a terminal:

  ```sh
  claude plugin marketplace add Miguel-Barroso/claude-warmline
  claude plugin install warmline@claude-warmline
  ```

  or `/plugin marketplace add …` and `/plugin install …` inside a session.
  This repo is that marketplace — [`.claude-plugin/marketplace.json`](../.claude-plugin/marketplace.json)
  points at the same `plugin/` folder.
- **One copy.** Two would draw two bands. The installer and `warmline setup`
  read `~/.claude/plugins/installed_plugins.json`: with a marketplace copy
  present they install none of their own, and remove one they installed
  earlier. A `skills/warmline` folder that isn't warmline's plugin is never
  touched either way. `warmline status` reports `INCONSISTENT` if it ever finds
  both copies.

Edits to the installed folder hot-reload in open sessions. `claude plugin
validate --strict plugin` and `claude plugin test plugin` are the checks, and
`./test.sh` runs them wherever `claude` is on `PATH`.

## Why the auditor does reach them

Every *local* front end runs the same engine and records the same JSONL
transcripts in the same place: `$CLAUDE_CONFIG_DIR/projects/<slug>/<session>.jsonl`
(default `~/.claude/projects`). A desktop session's own metadata file even
carries the `cliSessionId` under which its transcript is filed.

Verified on this machine: a Code-tab session's transcript grades normally —

```
$ warmline-audit ~/.claude/projects/-Users-mb-Development/00dad0e2-….jsonl
cache health  ██████████████████████████  98% hot  (103 of 105 turns)
105 API turns; HOT 103  PARTIAL 2
```

So `warmline audit --all` already covers your desktop sessions — they're in the
ranking with everything else, no flag needed. (The same is expected of the IDE
extensions, which bundle the same engine and share `~/.claude`; the desktop
case is the one we confirmed end to end.)

**SSH sessions** run the engine on the remote host, which reads *its* home
directory: install warmline there and audit there.

## Why keep-warm reaches them

The policy is text in `~/.claude/CLAUDE.md`, and desktop and CLI share
configuration and memory files — [Anthropic's own
docs](https://code.claude.com/docs/en/desktop) put it as "Desktop runs the same
underlying engine … they share configuration and project memory". So the
instruction is in front of the agent in a desktop session exactly as in a
terminal one.

What differs is the *scheduling mechanism* the agent reaches for: the CLI has
`ScheduleWakeup` (or the `/loop` fallback), the desktop app has Scheduled
tasks. Neither is guaranteed on every build, which is why the policy is written
to degrade to "simply inert" rather than to fail loudly — and why
[`warmline audit`](AUDIT.md) is the way to check whether a long wait actually
stayed warm.

## Cloud sessions: entirely out of reach

This page is the authoritative word on the subject, because it is easy to
misread the docs here: **no part of warmline works for Cloud, Cowork or
Dispatch sessions.** Those sessions run on Anthropic's infrastructure, not on
the engine on your machine, and everything warmline is built on stays local —
the statusline isn't rendered there, the transcripts they produce never land
in your `~/.claude/projects` (so the auditor and `warmline watch` have nothing
to read), and your local `~/.claude/CLAUDE.md` — where the keep-warm block
lives — is never part of a cloud session's context. Statements elsewhere about
warmline working beyond the terminal refer to the *local* graphical front ends
(the desktop app's Code tab, the IDE panels), which run the same engine on
your machine; cloud sessions do not.

## Windows

Native Windows and WSL are both supported, as two separate installs: native
Claude Code reads `%USERPROFILE%\.claude`, Claude Code in WSL reads the
distro's `~/.claude`, and each needs its own warmline. On native Windows the
installer runs from Git Bash and wires the status line with an explicit
interpreter (`py -3 "C:/Users/you/.claude/warmline-statusline.py"`), because
Claude Code may run it through PowerShell, which won't execute a bare `.py`.
See [installing](INSTALL.md#windows) for the details.
