# Where warmline works

[← back to the README](../README.md)

Claude Code is one engine behind several front ends. warmline is three
independent pieces, and they don't all reach every front end:

| Front end | statusline | `warmline audit` / `watch` | keep-warm policy |
|---|---|---|---|
| Terminal CLI (`claude`) | ✅ | ✅ | ✅ |
| Desktop app — Code tab, local session | ❌ not rendered | ✅ same transcripts | ✅ same CLAUDE.md |
| VS Code / JetBrains extension panel | ❌ not rendered | ✅ | ✅ |
| CLI inside an IDE's integrated terminal | ✅ | ✅ | ✅ |
| Desktop app — SSH session | ❌ | ✅ *on the remote host* | ✅ *on the remote host* |
| Cloud / Cowork / Dispatch sessions | ❌ | ❌ nothing local to read | ❌ local CLAUDE.md never reaches them |

**Short version for the desktop app: two of three.** The gauge is terminal-only,
but the auditor — including the live [`warmline watch`](AUDIT.md#which-sessions-are-warm-right-now---live--warmline-watch)
view — and keep-warm work exactly as they do in the CLI. `watch` in a terminal
window beside the app is the closest thing to a desktop statusline today.

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

Workaround, if you want the gauge while working in the desktop app: open the
integrated terminal (**Ctrl+`**) and run a `claude` session there for the work
where cache economics matter — or keep a CLI session in a terminal window
beside the app.

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

The statusline and the auditor are pure standard-library Python and don't care
about the OS; only the installer and the test suite are bash. See
[installing](INSTALL.md#windows) for the manual three-step install.
