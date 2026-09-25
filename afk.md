---
description: Go AFK -- warmline keeps this session's prompt cache warm until you come back
argument-hint: "[how long, e.g. 3h -- default and ceiling set by warmline afk enable]"
disable-model-invocation: true
---
<!-- claude-warmline afk: written by 'warmline afk enable'; 'warmline afk disable' removes it -->
## AFK mode: keep this session's prompt cache warm until the user is back

The user is stepping away and has asked warmline to keep this session's prompt cache warm while they are gone. They opted into this themselves, in their own terminal, with `warmline afk enable` -- accepting that unattended, automated requests may breach Anthropic's terms and put their account at risk. Every AFK turn is a billed request against their plan, so keep each one as small as possible: no summaries, no extra tool calls, no other work.

1. Run `{{WL}} afk start $ARGUMENTS` in the foreground.
   - Exit 0: AFK is on. Go to step 2.
   - Any other exit: AFK did not start. Relay the command's reason to the user in a line or two and stop. Never run `warmline afk enable` yourself, and never add a flag the user did not type (such as `--allow-5m`): consent is theirs to give, in their own terminal.
2. Run `{{WL}} afk wait` as a **background** task, then end the turn with one short line -- for example: "AFK: keeping the cache warm until you're back (at most until the time `afk start` printed). Just type when you return."
3. Each time that background task finishes you are woken with its result. Act on its exit code (its last line says the same in words), and nothing else:
   - **3** -- the cache is about to expire. Run `{{WL}} afk wait` in the background again and end the turn with a single short line. This turn *is* the keep-warm ping: no other tools, no recap.
   - **Killed or interrupted** (no exit code, 137, 143) -- the harness ended the task, not warmline. Treat it like 3: re-arm the same way.
   - **0** -- AFK is over: the user came back, ran `warmline afk stop`, or a newer wait took over. Do not re-arm. If the user has written, answer them; otherwise end the turn silently.
   - **1** -- the AFK time limit was reached, **4** -- the cache went cold anyway (the machine probably slept), so paying for a rebuild would be pointless. Either way AFK has ended: do not re-arm; end the turn with one line saying which.
   - **2**, or anything else -- AFK failed. Do not retry; say so in one line.
4. Any message from the user ends AFK automatically (warmline's prompt hook does it), and the background wait exits by itself within a minute. Don't re-arm it -- just help them.

While AFK: never start other work, never edit files, and never `/compact` -- compaction rewrites the prefix and throws away exactly the cache this is keeping warm.
