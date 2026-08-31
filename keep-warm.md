## Keep the prompt cache warm during long background waits

When launching background work expected to run longer than ~45 minutes (CI, long builds, remote jobs) while conversation context is substantial (above roughly 30% used), arrange for something to re-enter the session about every 50 minutes before going quiet. Any mechanism works if it fires well inside one TTL and can be removed again — a wakeup scheduler, a one-shot cron entry, a recurring prompt (`/loop 50m <no-op ping>`) — so use whatever this build offers. On each wake: if the work is still running, re-arm and end the turn without doing anything else; otherwise continue normally, and the results land against a hot prompt cache. Remove the wakeup the moment work resumes. Hard stop: after ~12 re-arms (~10 hours) let the cache expire — past that the pings cost more than the one rebuild they prevent, and this policy must never become unattended perpetual pinging.

Prefer a poller to a timed ping whenever the wait is locally observable: one backgrounded loop that exits when the job does (`warmline wait-for --pid N`, or `--log FILE --until PATTERN`) wakes the session on completion *and* on failure, needs no schedule, and cleans itself up. Schedule pings only for waits nothing local can watch.

Skip entirely when:

- **Local background tasks are already in flight.** Their notifications wake the session well inside the TTL, keeping the cache warm for free (measured: a ~9-minute notification cadence held a 300k context hot for hours).
- **Context is small.** A cold read of a small context is cheap; wakeups aren't worth it.
- **Context is near the auto-compact threshold** (~84% of the window, measured). Compaction rewrites the prefix and voids the warmth — compact first, then wait.

Why: the prompt cache expires after a TTL (~1 hour idle on subscription plans — Claude Code writes the `ephemeral_1h` bucket). A wakeup refreshes it for the price of one cache read (~0.1× input); resuming after expiry pays a full re-write (~2× input) across the whole context, plus uncached latency exactly when a wave of results arrives. Every ping is an ordinary billed request against the user's own plan or budget — keep-warm trades one expensive rebuild for a few cheap reads; it never creates free warmth or bypasses any limit.

Known limits, so don't over-promise warmth: nothing fires while the host sleeps (treat a resume after host sleep as cold; `warmline awake` — `caffeinate -is` on macOS — holds sleep off for exactly one session), and any prefix rewrite invalidates the cache regardless of timing: don't `/compact` mid-wait, and remember that auto-compact does the same thing without asking.
