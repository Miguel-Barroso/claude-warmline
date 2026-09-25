# AFK mode

[← back to the README](../README.md)

> **At your own risk.** AFK mode sends automated requests from a Claude Code
> session nobody is sitting at. That may breach Anthropic's terms and can get
> your account rate-limited, suspended or banned. It is off until you turn it on
> yourself and accept that risk, and warmline accepts no liability for it.

You're deep in a big session and it's time for lunch, a meeting, or bed. When
you come back an hour or more later, the prompt cache has expired and your first
message pays to rebuild the whole context at about 2× the input price, which is
the most expensive turn of the session. [Keep Warm](KEEP-WARM.md) doesn't cover
this. It only pings through a *job* the agent is waiting on, and it stays
deliberately clear of pinging for a person who has simply walked away.

AFK mode does exactly that, when you ask for it:

```text
> afk
  AFK: keeping the cache warm until you're back (at most until 23:10). Just type when you return.

  ... 2h40m later ...

> ok, where were we?
  warmline: welcome back -- AFK ended (away 2h40m, 3 keep-warm pings)
```

Three pings, each a cache read at about 0.1× input, instead of one rebuild at 2×.
The cache is hot when you return, and the reply comes back at warm-cache speed.

## Turning it on

```sh
warmline afk enable          # prints the risk, asks you to type "I accept the risk"
```

Enabling prints what AFK mode does and what it risks, then waits until you
type `I accept the risk`. Then it:

- writes the `/afk` slash command to `~/.claude/commands/afk.md`,
- adds a `UserPromptSubmit` hook to `~/.claude/settings.json`, so a plain `afk`
  message works and any other message ends AFK,
- adds a permission rule for `warmline afk …`, so a ping never stalls on a
  permission prompt that nobody is there to answer,
- records your consent in `~/.claude/warmline-afk/consent.json`.

Sessions pick these up when they start, so restart any session that's already
open.

**Consent has to come from you.** `enable` refuses to run from inside a Claude
Code session, even with the non-interactive flag, because the agent's shell
carries `CLAUDECODE` and `CLAUDE_CODE_SESSION_ID`. The `/afk` procedure also
tells the agent never to enable AFK for you. For scripted setups, run
`warmline afk enable --i-accept-the-risk` in your own terminal.

```sh
warmline afk enable --max-hours 6   # the default limit per AFK stretch (1-24, default 10)
warmline afk status                 # ON/OFF, wiring, who is away now; exit 0 / 1 / 2
warmline afk disable                # unwire everything and forget the consent
```

## Using it

In any Claude Code session, whether in the terminal CLI or the desktop app's
Code tab:

| You type | What happens |
|---|---|
| `afk` · `brb` | AFK until you're back, up to your default limit |
| `afk 3h` · `afk for 90 minutes` · `/afk 2h` | the same, with a shorter (or longer, up to 24h) limit for this stretch |
| *anything else* | you're back: AFK ends and your message is answered normally |

The hook only treats a message as a request to go AFK when the whole message is
`afk`, `brb`, or one of those followed by a duration. A message like "afk mode is
broken, fix it" is an ordinary message.

The statusline, in the terminal, shows `afk since 13:10, 2 pings` in yellow
while the session is away.

## How it works

1. `afk` (or `/afk`) gives the agent a short procedure. It runs
   `warmline afk start`, which checks your consent, reads the session's cache
   bucket from its transcript and writes a marker for this session.
2. The agent starts `warmline afk wait` as a **background task** and ends its
   turn. The waiter polls this session's cache expiry, the same number
   [`wait-for --until-cold`](KEEP-WARM.md#--until-cold-wake-on-the-deadline-not-on-a-timer)
   reads, and holds off system sleep while it runs (`caffeinate` on macOS,
   `systemd-inhibit` on Linux).
3. About three minutes before the cache would expire, the waiter exits with
   code **3**. The task notification wakes the session, the agent re-arms the
   waiter and ends the turn. That turn is the ping: one cache read of the
   prefix, which resets the TTL clock.
4. When you type, the hook removes the marker before your message reaches the
   model and tells the agent AFK is over. The waiter sees the marker gone and
   exits 0 on its next poll.

| `afk wait` exit | meaning | the agent |
|---|---|---|
| 3 | the cache is about to expire | re-arms and ends the turn: the ping |
| 0 | you're back, `afk stop`, or a newer waiter took over | does nothing more |
| 1 | the time limit was reached | stops; the cache is left to expire |
| 4 | the cache went cold anyway (the machine slept) | stops rather than pay for a rebuild |
| 2 | no session, transcript or AFK state | reports it |
| *killed* | the harness ended the background task (seen at ~25 and ~78 min) | re-arms, as for 3 |

## Bounds that stay on

AFK mode loosens Keep Warm's one bound, "only while a job runs". Everything else
stays in place:

- **One waiter per session.** Starting a waiter takes over the session's slot,
  and the older one exits 0. If the agent re-arms twice, the pings don't double.
- **A limit on every stretch.** The default is 10h, set with
  `enable --max-hours`, and the hard ceiling is 24h whatever is asked. After
  that the session is left to go cold.
- **No rebuilds.** If the cache has already expired, for example because the lid
  was closed and the machine slept through a ping, AFK stops rather than send a
  ping that would rebuild the cache at full price.
- **No 5-minute caches unless you ask.** Keeping a 5-minute cache warm takes a
  ping every ~3 minutes, about 20 an hour. Within the hour that costs more than
  the 1.15× rebuild it prevents, and it's the traffic that looks most like a bot.
  `afk start` refuses with exit 6. `--allow-5m` overrides it, and the agent is
  told to pass it only if you typed it.
- **Local only.** Nothing runs outside a live Claude Code session: no daemon, no
  cron. Quit Claude Code and AFK is over.

On the usual 1-hour cache that comes to about one ping every 57 minutes, so a
10-hour lunch-to-evening stretch costs about ten cache reads.

## The risk, plainly

Anthropic has not said whether this is allowed, so read the following as
warmline's understanding, not legal advice:

- Anthropic's Consumer Terms restrict accessing the services "through automated
  or non-human means" except where Anthropic permits it. Claude Code is
  permitted automation *while you use it*. A session re-prompting itself while
  you're away is a different thing, and whether it's allowed is Anthropic's
  decision, not warmline's.
- Anthropic added weekly limits specifically to curb accounts running Claude
  Code continuously in the background. AFK mode is bounded, but it is still
  background traffic.
- **On a Pro or Max subscription the risk is highest.** With an API key
  (Console billing, Bedrock, Vertex) automated use is normal and you pay for
  every token, so the terms question mostly goes away and only the cost
  remains.
- Every ping is billed to your plan or key. AFK mode only saves money if you
  come back to the session. If you might not, `/clear` or quit instead.

[Keep Warm's research into the terms](KEEP-WARM.md#is-this-within-anthropics-terms)
concluded that a bounded ping while a job runs stays well away from the behavior
Anthropic has acted against. AFK mode gives up that margin on purpose, which is
why it asks for your consent first.

## Where it works

| Front end | `afk` / `/afk` | statusline `afk` field |
|---|---|---|
| Terminal CLI | ✅ | ✅ |
| Desktop app, Code tab (local) | ✅ same `~/.claude` hooks and commands | ❌ no statusline there |
| VS Code / JetBrains panel | ✅ | ❌ |
| Cloud / Cowork sessions | ❌ nothing local | ❌ |

It needs a Claude Code build that exports `CLAUDE_CODE_SESSION_ID` to its
tools. Every current build does. Without it `afk start` exits 2 and says why.

## Troubleshooting

- **`afk` gets an ordinary answer.** The hook isn't loaded. Run
  `warmline afk status`, then restart the session: hooks and commands are read
  at session start.
- **The agent says AFK isn't enabled.** Run `warmline afk enable` in your own
  terminal.
- **Came back cold anyway.** The machine probably slept before the waiter could
  hold it awake (lid closed, or battery on macOS, where `caffeinate -s` doesn't
  apply). `warmline audit` shows the rebuild. For long absences, start the
  session under [`warmline awake`](KEEP-WARM.md#no-sleep-mode-warmline-awake).
- **Stop it from another terminal:** `warmline afk stop --all`.
- **Your own `/afk` command:** if `~/.claude/commands/afk.md` already exists and
  isn't warmline's, it's left alone. `/afk` runs your command and the plain `afk`
  message still works.
