## Keep the prompt cache warm during long background waits

When launching background work expected to run longer than ~45 minutes (CI pipelines, long builds, long-running remote jobs) while conversation context is substantial (above roughly 30% used), schedule a wakeup for ~50 minutes out before going quiet — via ScheduleWakeup if available, otherwise a recurring scheduled prompt (e.g. `/loop 50m <no-op ping>`). On each wake: if the work is still running, reschedule ~50 minutes out and end the turn without doing anything else; if it has finished, continue normally — the results then land against a hot prompt cache. Never let wakeups continue once the wait is over; delete the schedule the moment work resumes. Hard stop: once a single wait has been rescheduled ~12 times (~10 hours), stop rescheduling and let the cache expire — past that point the pings cost more than the one rebuild they prevent, and this policy must never turn into unattended perpetual pinging.

Skip scheduling entirely when:

- **Local background tasks are already in flight.** Their completion notifications wake the session well inside the TTL, keeping the cache warm for free (measured: ~9-minute notification cadence held a 300k context hot for hours at ~400 cache-write tokens per wake). Only schedule when the wait is *externally* quiet — nothing local will fire.
- **Context is small.** A cold read of a small context is cheap; wakeups aren't worth it.

Why: the provider prompt cache expires after a TTL (~1 hour of inactivity on subscription plans — Claude Code writes the `ephemeral_1h` bucket). A wakeup refreshes the TTL for the price of one cache read (~0.1× input), while resuming after expiry pays a full cache re-write (~2× input) across the entire context, plus uncached latency at exactly the moment a wave of results arrives. Every ping is an ordinary billed request against the user's own plan or API budget — keep-warm trades one expensive rebuild for a few cheap reads; it never creates free warmth or bypasses any limit.

Known limits, so don't over-promise warmth: wakeups cannot fire while the host machine sleeps (a resume after host sleep should be treated as cold; on macOS `caffeinate -is` keeps a planned wait awake), and `/compact` or any other prefix rewrite invalidates the cache regardless of timing — don't compact mid-wait if the plan is to stay warm.
