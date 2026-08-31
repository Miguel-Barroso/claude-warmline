# Keep Warm

[← back to the README](../README.md)

The statusline and the auditor *observe*. Keep Warm is the optional half that
*prevents*: it keeps the cache from expiring during long waits you intend to
come back to.

```sh
warmline keep-warm on        # turn it on (once)
warmline keep-warm status    # is it on, and is it current?
warmline keep-warm off       # turn it off
warmline wait-for --pid N    # the poller half (see below)
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

`policy modified` is also what an upgrade looks like from the inside: the
installer refreshes `~/.claude/warmline-keep-warm.md`, but the block your
agent actually reads lives in CLAUDE.md, and it is that block that decides
behavior. Since v1.8.0 the installer closes the gap — it rewrites a block you
never touched, and leaves a block you did — and the statusline shows the
divergence as [`keep-warm on*`](STATUSLINE.md#the-keep-warm-field) in yellow
rather than a confident green `on`.

`on` and `off` are idempotent and touch only warmline's own block — text before
and after it survives untouched.

## What it is

A short instruction block ([`keep-warm.md`](../keep-warm.md), installed to
`~/.claude/warmline-keep-warm.md`) that your agent follows during active
sessions. When it starts background work expected to exceed ~45 minutes while
context is substantial, it arranges for something to re-enter the session
~50 minutes out; on wake, it re-arms if the work is still running, otherwise
continues normally — and the results land against a hot cache.

The policy names no particular scheduler. It states the requirement — some
mechanism must re-enter the session inside one TTL, and must be removable
again — and leaves the choice to whatever the running build offers. That
matters more than it sounds: a real 4.5-hour session had neither
`ScheduleWakeup` nor `/loop`, only one-shot cron entries, and an earlier
wording that named two specific tools would have read as "not applicable
here".

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
- **No mechanism at all.** Builds differ in what they expose — a wakeup
  scheduler, cron, a recurring prompt, a background task. If none of them
  exists and the wait isn't locally observable either, the block is inert.
- **A rewritten prefix.** `/compact` — or any other prefix change —
  invalidates the cache regardless of timing. Don't compact mid-wait; and see
  [auto-compact](#auto-compact-the-one-you-dont-choose) for the half you don't
  control.
- **It's an instruction, not code.** The agent can fail to follow it.
  [`warmline-audit`](AUDIT.md) is how you verify it actually worked: look for
  ~400-token cache writes at ~50-minute intervals instead of a full re-cache.

## Waiting on work you launched yourself: `warmline wait-for`

A timed ping is the right tool for a wait nothing local can observe — a CI
run on someone else's infrastructure, a queue you can only poll by API. When
the job is running *on this machine*, a poller beats a ping outright: it
wakes the session on completion **and on failure**, needs no schedule, and
ends itself. There is nothing to remember to delete.

```sh
warmline wait-for --pid 4242
warmline wait-for --pidfile /tmp/backup.pid
warmline wait-for --file /tmp/backup.done            # done when it appears
warmline wait-for --log /tmp/backup.log --until 'transfer complete'
```

It polls every 30s (`-n`), prints a heartbeat every 50 minutes (`--every`,
inside the TTL, `0` to stay silent), and gives up after 10 hours
(`--timeout`, `0` to wait forever) — the same bounds as the policy. Exit `0`
means the watched job ended, `1` timed out, `2` bad usage **or a target that
never appeared**: a pidfile that stays empty is a launch bug, and you want to
hear about it in the first five minutes, not at hour ten.

### The `&` trap

This is the failure that makes the command worth shipping. Launching

```sh
nohup bash -c 'long job' > job.log 2>&1 &      # inside a background task
```

returns *immediately*. The harness sees its wrapper exit, reports the task
**completed, exit 0**, and the real work carries on detached with nothing left
to notify anybody. You get a completion signal at minute zero and silence for
the next four hours — which is precisely the wrong shape for keep-warm, since
the "it finished" wake fires before the wait even starts.

### The paired pattern

The two mechanisms fail in opposite directions:

| | survives a harness restart | notifies on exit |
|---|---|---|
| in-harness background task | ❌ — observed dying at ~25 and ~78 min with a bare `[killed]` | ✅ |
| detached `nohup … & disown` | ✅ | ❌ |

So pair them: **detach the worker, then watch it from inside.**

```sh
# 1. the worker, deliberately detached, writing its own pid down
nohup bash -c 'echo $$ > /tmp/job.pid; long job' > /tmp/job.log 2>&1 &
disown

# 2. as a harness background task: short-lived, restartable, notifies
warmline wait-for --pidfile /tmp/job.pid
```

The worker survives whatever happens to the harness. The poller carries the
notification, and if *it* gets killed, restarting it costs one command and
loses nothing — the worker never noticed. (The two deaths above were not
explained by host sleep, device disconnection or a transfer error, all of
which were checked; harness lifecycle is the inference, not a proven cause.
The pattern is worth using either way, because it costs nothing when the
guess is wrong.)

## Auto-compact: the one you don't choose

In the 4.5-hour session that prompted these notes, keep-warm did its job —
187 turns, 96% HOT, **zero** tokens re-cached cold. Every single break in
warmth was an *auto*-compaction. Advice about not typing `/compact` mid-wait
does nothing about that, so here is the honest picture.

**What it is.** Claude Code compacts on its own when the context window
fills. In that session it fired three times at 167–169k input tokens — about
**84%** of a 200k window, consistent with a threshold set a fixed distance
below the window. Compaction rewrites the prefix, so the next turn re-caches
from the divergence: a `PARTIAL` in [`warmline-audit`](AUDIT.md), attributed
to `auto-compact`.

**What can actually be done.**

- **Don't start a keep-warm wait near the threshold.** This is the only
  advice in the policy block, because it's the only one an agent can act on
  mid-session: past ~80% the prefix is about to be rewritten anyway, so the
  pings buy nothing. Compact first, deliberately, then wait — a compaction
  you choose while the cache is *cold or about to die* is nearly free, which
  is the same argument the README makes for `/compact` after `COLD(ttl?)`.
- **See it coming.** The statusline paints `ctx` yellow past 80%
  (`WARMLINE_CTX_WARN_PCT`). That's a handful of turns of warning, not a lot
  — but auto-compact is otherwise entirely silent until it happens.
- **Turn it off, if you accept the trade.** Auto-compaction is a setting, not
  a law: `autoCompactEnabled: false` in `~/.claude/settings.json`, or
  `DISABLE_AUTO_COMPACT=1` in the environment. Then nothing rewrites your
  prefix unasked — and nothing saves you when the window fills either; you
  hit a hard wall and compact by hand. Worth it only for a deliberate long
  wait you have sized to fit.

**What can't.** Nothing keeps a prefix warm across a rewrite. Compaction
*is* the rewrite; the cache it invalidates was never recoverable. warmline
can tell you it happened, and roughly when it's coming. It cannot prevent it,
and no wording in the policy block would change that.

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

`install.sh` respects that distinction on every upgrade. If the block still
matches the policy it replaced, it is rewritten in place and the installer
says so; if it doesn't — you edited it — it is left exactly as it is, with a
note telling you the wording moved on and how to adopt it. Your own text
before and after the markers is never touched either way.

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
