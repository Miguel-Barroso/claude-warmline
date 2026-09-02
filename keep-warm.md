## Keep the prompt cache warm during long background waits

When launching background work expected to run past ~45 minutes (CI, builds, remote jobs) while the statusline's `cache` field shows a rebuild worth keeping — the token figure beside HOT, ~50k up — arrange for something to re-enter the session every 50 minutes before going quiet. Any mechanism works that fires well inside one TTL and can be removed again: a scheduler, a one-shot cron entry, a recurring prompt (`/loop 50m <no-op ping>`). On each wake, re-arm and end the turn if the work is still running; otherwise continue normally, against a hot cache. Remove the wakeup the moment work resumes. Hard stop: after ~12 re-arms (~10 hours) let it expire — past that the pings cost more than the rebuild they prevent, and this must never become unattended perpetual pinging.

Prefer a poller to a timed ping whenever the wait is locally observable: one backgrounded loop that exits when the job does (`warmline wait-for --pid N`, or `--log FILE --until PATTERN`) wakes the session on completion *and* on failure, with no schedule to remove. `--until-cold` also returns it just before this session's cache really expires, read from its own transcript; alone, it replaces a scheduled ping for waits nothing local can watch.

Skip entirely when:

- **Local background tasks are already in flight.** Their notifications wake the session well inside the TTL, keeping the cache warm for free (measured: a ~9-minute cadence held 300k hot for hours).
- **The session is on a 5-minute cache** — the statusline reads `cache HOT 5m`. Holding one warm costs ~12 pings an hour against a 1.15× premium; break-even is ~11.5, so it never pays.
- **Context is near the auto-compact threshold** — the last ~33k tokens of the window, where `ctx` turns yellow. Compaction rewrites the prefix and voids the warmth: compact first.

Why: the cache expires after a TTL (~1 hour idle on subscription plans — Claude Code writes the `ephemeral_1h` bucket). A wakeup refreshes it for one cache read (0.1× input); resuming after expiry re-writes the whole context (2× input on the 1-hour bucket), plus uncached latency exactly when results arrive. Every ping is an ordinary billed request on the user's own plan: keep-warm trades one expensive rebuild for a few cheap reads, and never creates free warmth or bypasses a limit.

Known limits: nothing fires while the host sleeps (treat a resume after sleep as cold; `warmline awake` — `caffeinate -is` on macOS — holds it off for one session), and any prefix rewrite invalidates the cache whenever it happens: don't `/compact` mid-wait, and auto-compact does the same without asking.
