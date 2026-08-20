# Keep Warm

[← back to the README](../README.md)

The statusline and the auditor *observe*. Keep Warm is the optional half that
*prevents*: it keeps the cache from expiring during long waits you intend to
come back to.

```sh
warmline keep-warm on        # turn it on (once)
warmline keep-warm status    # is it on?
warmline keep-warm off       # turn it off
```

It's global — one marker-delimited block in `~/.claude/CLAUDE.md` — applies to
every project, and persists across sessions and installer updates. Set and
forget. (`./install.sh --keep-warm` runs the same enable at install time;
`--uninstall` removes it along with everything else.) The
[statusline](STATUSLINE.md) shows the current state as `keep-warm on|off`.

## Status is read, never remembered

```
$ warmline keep-warm status
keep-warm  ON
  scope    global -- applies to every project  (block in /Users/mb/.claude/CLAUDE.md)
  policy   intact
```

`status` never trusts a state file — it reads your actual CLAUDE.md every
time. Hand-delete the block and it reports OFF; leave half a block behind and
it reports INCONSISTENT, with the fix, rather than a false ON; edit the policy
text in place and it stays ON but reports `policy modified`. For scripts, the
exit code is the answer: `0` on, `1` off, `2` inconsistent.

`on` and `off` are idempotent and touch only warmline's own block — text before
and after it survives untouched.

## What it is

A short instruction block ([`keep-warm.md`](../keep-warm.md), installed to
`~/.claude/warmline-keep-warm.md`) that your agent follows during active
sessions. When it starts background work expected to exceed ~45 minutes while
context is substantial, it schedules a wakeup ~50 minutes out; on wake, it
reschedules if the work is still running, otherwise continues normally — and
the results land against a hot cache.

Each ping costs ~0.1× your context in cache-read quota versus ~2× for the cold
re-write, so it pays for itself for idle stretches up to roughly 10–12 hours
*if* you return.

## What it is NOT

- **Not a daemon.** No background process, no cron, no requests outside a
  running Claude Code session. When Claude Code isn't running, nothing runs.
- **Not always-on.** It deliberately *skips* when local background tasks are
  already in flight (their notifications keep the cache warm for free — see
  [what we measured](MEASUREMENTS.md)), and skips small contexts, where going
  cold is cheap.
- **Not persistent past the wait.** Wakeups are deleted the moment work
  resumes, and a single wait gives up after ~12 reschedules (~10 hours) — past
  that the pings cost more than the rebuild they prevent.

## When it cannot operate

- **A sleeping host.** Wakeups can't fire while the machine is asleep —
  [no-sleep mode](#no-sleep-mode-warmline-awake) exists for exactly this.
- **No scheduling mechanism.** `ScheduleWakeup` may be absent, or present but
  gated, on some Claude Code builds — the agent then falls back to a recurring
  scheduled prompt (`/loop 50m <ping>`), or the block is simply inert.
- **A rewritten prefix.** `/compact` — or any other prefix change — invalidates
  the cache regardless of timing. Don't compact mid-wait if the plan is to stay
  warm.
- **It's an instruction, not code.** The agent can fail to follow it.
  [`warmline-audit`](AUDIT.md) is how you verify it actually worked: look for
  ~400-token cache writes at ~50-minute intervals instead of a full re-cache.

## No-sleep mode: `warmline awake`

The one limit keep-warm cannot prompt its way around is a sleeping host — no
wakeup fires with the lid closed. For a wait you plan to sit out, start the
session in no-sleep mode:

```sh
warmline awake                    # run 'claude' with system sleep held off
warmline awake claude --resume    # ...or wrap any command
```

It wraps the session in the OS's own sleep inhibitor (`caffeinate -is` on
macOS, `systemd-inhibit` on Linux), so system and idle sleep are prevented for
as long as the session runs — and *only* that long. The inhibition's lifetime
is the wrapped process's lifetime: when you `/exit`, when the session crashes,
when you ctrl-c it, the operating system releases the assertion and normal
sleep behavior returns. There is no state file, no daemon and no cleanup step,
so your machine cannot be left permanently sleepless. The display may still
sleep; only the machine stays up.

Deliberately session-scoped, not a setting: an always-on no-sleep flag would
outlive the wait it was meant for, which is exactly the failure mode keep-warm
itself is designed to avoid.

## Editing the policy

The installed copy at `~/.claude/warmline-keep-warm.md` is the source
`warmline keep-warm on` appends. Edit it, then `warmline keep-warm off &&
warmline keep-warm on` to refresh the block in CLAUDE.md. If you edit the block
inside CLAUDE.md directly, `status` reports `policy modified` so you know the
two have diverged.

## Is this within Anthropic's terms?

We researched this rather than assuming. The mechanism keep-warm relies on is
documented product behavior: Anthropic's
[prompt-caching docs](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)
state the cache "is refreshed at no additional cost each time the cached
content is used", and for API use they explicitly recommend periodic pre-warm
requests. A keep-warm ping is an ordinary billed request inside a live session:
it consumes your own quota (usually *less* than the cold rebuild it replaces)
and bypasses nothing.

The boundary that matters is on the other side — Anthropic's weekly limits
exist to curb accounts running Claude Code continuously, 24/7. That is why this
policy is bounded by design: it pings only through a genuine wait you intend to
return to, at most about once per 50 minutes, skips when warmth is already
free, stops the moment work resumes, gives up after ~10 hours, and is never a
daemon. Don't loosen those bounds.

One honest unknown remains: whether scheduled pings inside a consumer Claude
Code session count as the "ordinary, individual usage" the subscription plans
assume is not addressed anywhere we could find — Anthropic's exact position on
this specific use is unknown. None of this means Anthropic endorses keep-warm —
it means we found no rule it breaks, and built it to stay far from the behavior
Anthropic has acted against.
