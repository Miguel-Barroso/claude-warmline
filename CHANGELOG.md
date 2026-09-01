# Changelog

This project follows [semantic versioning](https://semver.org). The "public API"
is the statusline output, the CLI of `warmline-audit` and `install.sh`, and the
`WARMLINE_*` environment variables.

## [2.0.0] — 2026-09-01

Claude Code v2.1.251 began handing the statusline a `prompt_cache` object — the
prefix's real warmth, its TTL, and the epoch second it expires. Every live cache
fact warmline used to *infer* is now **read**, and the machinery that did the
inferring is gone. Claude Code owns live truth; warmline presents it and owns
cross-session history. Verified against a running 2.1.252; see
[docs/STATUSLINE.md](docs/STATUSLINE.md).

### Fixed
- **`cache HOT` on a cache that was already cold.** The verdict came from
  `cache_read_input_tokens`, which describes the request *before* this one, so a
  session that had gone quiet long enough to lose its prefix still painted a
  confident green — the gauge was wrong precisely when it mattered, on the idle
  session it exists to watch. Warmth now comes from `prompt_cache.warm`, and a
  regression test pins the old failure: `warm: false` beside a 165k-token cache
  read renders `COLD`.
- **A `warm: false` carrying a stale expiry.** At expiry 2.1.252 flips `warm` to
  `false` but leaves `expires_at` at its old value rather than nulling it, which
  the docs don't say. `warm` is therefore checked before the clock, and the clock
  is only ever used for the label. Also pinned by a test.

### Added
- **`cache off`.** `caching_observed: false` — no response this session ever
  reported cache tokens, so prompt caching is off, or this provider or gateway
  never reports it. Nothing here will warm up, which is not the same as a cache
  you can wait out.
- **`cache ?`.** No `prompt_cache` object at all: Claude Code before v2.1.251, or
  before the session's first API response. Honest ignorance instead of a guess,
  gated on the shape of the payload rather than on a version string.
- **`HOT 5m`.** The short TTL is badged because it invalidates the mental model
  built on the hour — it is what usage credits, an API key and cloud providers
  give you, and it breaks keep-warm outright. The 1-hour bucket is the norm and
  stays unlabelled; a field that reads the same for three months stops being
  read.

### Changed
- **`COLD`, `off` and `?` are three verdicts, not one.** "It expired", "caching
  isn't happening" and "warmline can't see" each call for something different,
  and collapsing them is how a cache gauge starts lying.
- **`refreshInterval: 60` is warning UX, not correctness.** Claude Code re-runs a
  statusline when the warm cache it last sent reaches `expires_at`, and warmline
  has now watched it fire: a session sitting silent — no user message, no
  assistant message, polling parked at an hour — was re-run at expiry+1s with
  `warm: false` and repainted itself red. Refreshing before expiry replaces that
  trigger rather than stacking on it. So the trigger owns `HOT` → `COLD`, and the
  timer is kept for the one thing a single shot at expiry cannot do: repaint when
  the warning window *opens*, 15 minutes earlier, in a session generating no
  other events. In that same run the line went green straight to red and the
  yellow never rendered. `WARMLINE_REFRESH_SEC=0` still leaves a correct gauge —
  it just stops warning you first.
- **The warning window is capped at half the TTL**: 15 minutes of an hour, 2.5 of
  five, 15 for a `ttl` string warmline doesn't recognise. A flat 15 minutes is
  longer than a 5-minute cache ever lives, and a warning that is always on is not
  a warning.

### Removed
- **All live cache inference.** The transcript TTL sniffing, the per-session
  stamp files and the `warmline-state` directory they lived in (deleted on
  upgrade), the session-state protocol, and the staleness handling each of those
  needed. The statusline now reads no transcript and writes no file.
- **`WARMLINE_TTL_MIN`, `WARMLINE_STATE_DIR` and `WARMLINE_DEBUG` from the
  statusline.** `WARMLINE_TTL_MIN` remains an auditor knob:
  [`warmline audit`](docs/AUDIT.md) still infers a TTL per session, because
  historical transcripts contain no `prompt_cache` to read. That split is the
  design — live truth from Claude Code, history from warmline.
- **`gap Nm`, `COLD(rebuilt)`, `COLD(ttl?)` and `(cold in Nm)` from the line.**
  The gap fed the inference; the two `COLD` variants were an inference reported
  as a verdict; the countdown was wrong the moment the line stopped repainting,
  where the absolute `cold ~13:04` stays true. The auditor keeps `COLD(rebuilt)`
  and `COLD(ttl)`: there the verdict is graded from recorded usage, and the split
  between the two rests on the TTL it infers per session — bounded inference over
  transcripts that carry no authoritative payload, which is a different job from
  the live line's.
- **`keep-warm on` in the normal case.** The field now appears only when the
  policy needs attention (`on*` stale, `?` malformed). A correct policy and a
  deliberate absence are both silent; `warmline keep-warm status` is where you
  ask.

Requires Claude Code **v2.1.251+** for a live verdict. Older builds render
`cache ?` — the line still works, it just declines to guess.

## [1.8.0] — 2026-08-31

Everything in this release comes from one 4.5-hour supervised wait with the
policy on: 187 turns, 96% HOT, **zero** tokens re-cached cold. Nothing was
broken; four things were less useful than they looked. See
[docs/MEASUREMENTS.md](docs/MEASUREMENTS.md#a-45-hour-session-with-the-policy-on).

### Added
- **`warmline wait-for TARGET` — a poller instead of a ping.** Blocks until a
  detached job finishes (`--pid N`, `--pidfile F`, `--file F`, or
  `--log F --until PATTERN`), so run as a harness background task it wakes the
  session *when the work ends* — on failure as well as success — with no
  schedule to arm, re-arm or forget to remove. The policy now prefers this to a
  timed wakeup whenever the wait is locally observable, and reserves scheduled
  pings for waits nothing local can watch. Bad targets fail loudly rather than
  blocking forever: an unparseable pidfile, a log that never appears, or a pid
  that was never a process exits 2 within five minutes saying the worker
  probably never started, and a zombie counts as finished (it answers `kill -0`,
  which is exactly the case a failed detach produces).
- **`keep-warm on*` — the statusline now says when your policy block is
  stale.** `warmline keep-warm status` has always reported "policy modified",
  but the gauge painted any present block plain green `on`, so an upgraded
  policy that never reached your CLAUDE.md looked identical to a current one.
  The field now compares the installed block against `warmline-keep-warm.md`
  and paints a yellow `keep-warm on*` when they differ — measured at 0.15 ms
  per render, against a 60-second refresh. Absent policy file, no star: the
  gauge doesn't cry wolf about a comparison it can't make.
- **A yellow `ctx` past 80%.** Auto-compaction is the one prefix rewrite nobody
  chooses, and it was the *only* cause of lost warmth in the field session — it
  fired three times at 167–169k of a 200k window (~84%). A high `ctx` is the
  only warning you get, so it turns yellow before the threshold, tunable with
  `WARMLINE_CTX_WARN_PCT` (`0` disables). The policy gained a matching skip
  clause: don't start a long wait just under the threshold; compact first.

### Changed
- **The policy no longer names mechanisms that may not exist.** It called for
  `ScheduleWakeup` "otherwise `/loop 50m`"; the field session's build offered
  neither (it had cron), and an agent reading a closed list of unavailable tools
  concludes the policy doesn't apply. It now states the *requirement* — anything
  that re-enters the session well inside one TTL and can be removed again — with
  schedulers, cron and recurring prompts as examples of it.
- **"Local background tasks are already in flight" is no longer only luck.**
  That skip clause read as a happy accident to notice; the agent can create the
  condition, and now the policy says so.
- **The `/compact` warning names auto-compact too.** Every warmth break in the
  field session came from the automatic one. `docs/KEEP-WARM.md` gains a section
  on what can actually be done about it (see it coming, don't wait near the
  threshold, `autoCompactEnabled: false` / `DISABLE_AUTO_COMPACT=1` and the
  hard-wall trade-off that comes with turning it off) rather than more words in
  the block.
- **Updating refreshes the keep-warm block inside your CLAUDE.md.** Previously
  an upgrade replaced `warmline-keep-warm.md` but left the copy in CLAUDE.md
  from whenever you first installed — the file your agent actually reads. The
  installer now rewrites a block that still matches the policy it replaced, and
  leaves a block you edited yourself alone with a console note and the two
  commands to adopt the new wording. The rest of your CLAUDE.md is untouched
  either way.

The block is 440 words (was 409) — about 50 more tokens on every request, spent
on the three findings above.

### Fixed
- **`warmline-audit --help` was broken.** It read `--help` as a transcript path
  and died with `no transcript found at '--help'`, which is why `--json` — the
  form to reach for when an agent, CI or a column-reflowing terminal proxy is
  reading — could only be found by grepping the source. Both are now documented
  in `--help` and in [docs/AUDIT.md](docs/AUDIT.md).

### Documentation
- The `&` trap: `nohup … &` inside a harness background task makes the *wrapper*
  exit immediately, so the harness reports "completed, exit 0" while the real
  work runs on detached with nothing left to notify you.
- The paired pattern: in-harness tasks notify on exit but can be killed by the
  harness (two died mid-session with a bare `[killed]`); detached `nohup`
  workers survive but notify nothing. Run both — detached worker, short-lived
  `warmline wait-for` poller — and you get survival *and* the wake.

## [1.7.0] — 2026-08-20

### Added
- **Input and output tokens are priced separately.** Claude bills them at
  different rates, so `warmline-audit` now does too: `--price` (alias
  `--price-in`) is the base *input* $/MTok that all cache economics are
  multiples of, and the new `--price-out` is the *output* $/MTok, reported on
  its own clearly-labeled line — output is never cached, so warmth can't save
  it, and the cache numbers can no longer be mistaken for the whole bill.
  Defaults come from the current Claude API price sheet rather than
  placeholders: bare `--price` means $3/MTok (Sonnet base input), and an
  omitted `--price-out` means 5× the input price, the ratio every current
  Claude model bills at ($3/$15, $5/$25, $1/$5, $10/$50). `--json` gains
  `tokens_output`, `output_usd` and the `price_*_per_mtok` used.
- **Percentages throughout the audit.** The verdict census shows each
  verdict's share of turns, every cause carries its share of cold-cause
  events (line and histogram), `--all`'s cold-events line shows the share of
  all turns, and the `--all` table gains a `share` column — each session's
  slice of all avoidable cold tokens — so the events and sessions most likely
  to be paying the cold-cache premium are obvious at a glance. Raw counts
  stay; percentages are display-only (`--json` is unchanged in kind).
- **`warmline awake [CMD...]` — no-sleep mode for one session.** Runs
  `claude` (or any command) wrapped in the OS's own sleep inhibitor
  (`caffeinate -is` on macOS, `systemd-inhibit` on Linux), so keep-warm
  wakeups survive a wait the machine would otherwise sleep through. The
  inhibition's lifetime *is* the session's: `/exit`, ctrl-c or a crash ends
  the wrapped process, and the OS releases the assertion — normal sleep
  behavior returns with no state to clean up and no way to be left
  permanently sleepless.

### Fixed
- **Cloud support documentation was contradictory.** The README's surface
  paragraph said "graphical front ends … work there unchanged", which — read
  against the table row above it — implied Cloud/Cowork sessions were covered;
  they are not. The claim is now scoped to the *local* graphical front ends
  (desktop Code tab, IDE panels), the keep-warm cell for cloud sessions is an
  explicit ❌ instead of an ambiguous —, and `docs/SURFACES.md` carries the
  one authoritative statement: no part of warmline reaches cloud sessions —
  no statusline surface, no local transcripts to audit, and the local
  CLAUDE.md (where the keep-warm block lives) is never part of their context.

## [1.6.0] — 2026-08-20

### Fixed
- **The stale `HOT` gauge.** Claude Code re-runs a statusline command on
  conversation events only, so a session that finished work and went quiet
  never repainted — the last-painted green `cache HOT` could sit on screen
  all evening while the cache had been cold since lunch. The installer now
  wires `statusLine.refreshInterval: 60` into `settings.json`, so the gauge
  re-renders every minute even while the session idles: the countdown ticks,
  and `COLD(ttl?)` takes over within a minute of the TTL passing. The
  refresh is a local repaint only — it never touches the API and does not
  keep the cache warm. `WARMLINE_REFRESH_SEC` tunes it at install time
  (`0` omits the key); a hand-edited value survives reinstalls; Claude Code
  versions without the setting ignore it harmlessly.

### Added
- **Absolute expiry time on the HOT verdict**: `cache HOT (cold ~13:04)`
  (last turn + TTL). Defense in depth for the same bug: on harnesses that
  never repaint an idle line (older Claude Code, a machine that slept
  through its timer), even a frozen line now tells you exactly when warmth
  ended.
- **`warmline watch`** (and its scriptable one-shot form,
  `warmline-audit --live [--json]`): a live table of every session with API
  turns in the last 24h — which prefixes the cache still holds right now
  and when each goes cold, warm sessions first, soonest-to-die on top.
  Computed from last-turn timestamps, so it has no one-turn lag and no
  repaint dependency, and it covers desktop-app sessions, which write the
  same transcripts but have no statusline surface. `-n SECS` sets the
  refresh cadence (default 10s).
- **TTL auto-detection.** Cache writes in transcripts record their bucket
  (`ephemeral_1h` vs `ephemeral_5m`), so the statusline and the auditor now
  detect each session's TTL from its own usage entries instead of assuming
  60 minutes — short-TTL setups work out of the box, and mixed-TTL history
  audits correctly. `--ttl` / `WARMLINE_TTL_MIN` force a value; 60m remains
  the fallback for transcripts that predate bucket recording. Audit output
  and `--json` say which was used (`ttl_source`: buckets / default /
  forced).
- `warmline status` gained a `refresh` row (self-refresh cadence, or a
  pointed note that the gauge is event-driven only), and its `ttl` row now
  reports the auto-detection default.

## [1.5.0] — 2026-08-19

### Added
- **Keep-warm state on the statusline.** The line now ends with
  `keep-warm on` (green), `off` (dim) or `?` (yellow, a malformed
  half-block) — read from `$CLAUDE_CONFIG_DIR/CLAUDE.md` on every render,
  the same source of truth `warmline keep-warm status` uses, so hand edits
  show up immediately. `on` means the policy is installed, not that a ping
  is scheduled. `WARMLINE_NO_KEEPWARM=1` omits the field.
- `docs/SURFACES.md`: which front ends each piece of warmline reaches.
  Short version: the statusline is terminal-only (graphical front ends
  don't render custom statuslines — anthropics/claude-code#41456), while
  `warmline-audit` and the keep-warm policy work unchanged in the desktop
  app and IDE extensions, which share `~/.claude` and write their
  transcripts to the same place. Verified by grading a desktop Code-tab
  session's transcript.

### Changed
- `warmline-audit` honors `CLAUDE_CONFIG_DIR` when locating transcripts,
  instead of hardcoding `~/.claude/projects` — matching the statusline and
  the `warmline` CLI.
- README cut roughly in half and reorganized around what a newcomer needs
  first; the reference material moved to `docs/` (`STATUSLINE.md`,
  `AUDIT.md`, `KEEP-WARM.md`, `SURFACES.md`, `INSTALL.md`,
  `MEASUREMENTS.md`). "Coming back cold: `/compact`, `/clear`, or neither?"
  stays on the front page in full. Translations regenerated to match.
- Hero image updated with the keep-warm field.

## [1.4.0] — 2026-08-19

### Added
- The `warmline` command. The installer installs; `warmline` controls:
  `warmline status` (what is installed and enabled right now),
  `warmline keep-warm on|off|status`, `warmline audit …` (runs
  `warmline-audit`), `--help` at both levels. `keep-warm status` exit
  codes are API: 0 = ON, 1 = OFF, 2 = INCONSISTENT. Status never trusts a
  state file — it reads the actual `~/.claude/CLAUDE.md` every time, and a
  malformed or hand-edited block is reported truthfully (INCONSISTENT /
  `policy modified`) instead of a false ON. `on`/`off` are idempotent and
  remove or append only warmline's marker-delimited block; unrelated
  CLAUDE.md content is preserved.
- `warmline` and `warmline-audit` are installed to `~/.local/bin`
  (override: `WARMLINE_BIN_DIR`) — `curl | bash` users previously never
  got the auditor at all. If that directory isn't on `PATH`, the installer
  prints the exact line to add; it never edits shell startup files. The
  policy text is installed to `~/.claude/warmline-keep-warm.md` so
  `warmline keep-warm on` works without a checkout.
  `install.sh --keep-warm` remains as install-time shorthand for
  `warmline keep-warm on`.
- Audit reports are visual on terminals: colored verdicts, a `cache health`
  bar, a `cold events` count and a "where the cold came from" cause
  histogram in `--all`, and a closing `estimated avoidable premium` line
  with `--price` — including a top-5-sessions concentration split showing
  whether the leak is a few disasters or spread thin. Piped/CI output
  stays plain (color is TTY-gated; `NO_COLOR`/`WARMLINE_NO_COLOR`
  respected, `WARMLINE_FORCE_COLOR` forces), bars degrade to `#`/`.` on
  ascii-only stdout, and `--json` is unchanged.
- Policy review (documented in the README as "Is this within Anthropic's
  terms?"): keep-warm relies on documented cache-TTL-refresh behavior and
  ordinary billed requests; whether scheduled pings count as "ordinary,
  individual usage" on subscription plans is honestly unknown. Following
  the review, `keep-warm.md` gained a hard stop (~12 reschedules ≈ 10
  hours per wait) and an explicit note that pings bill against the user's
  own quota.

### Changed
- README rewritten popular-science-first: a 30-second explainer, a Quick
  start with the canonical flow (install → `warmline keep-warm on` →
  `warmline keep-warm status` → audit), the observability ladder, a
  precise definition of "avoidable" (an estimate of exposure, not money
  actually wasted), and example outputs captured from real runs.
- `test.sh`: 18 → 45 cases (CLI state transitions ON/OFF in every order,
  malformed-block truth-telling, unrelated-CLAUDE.md-content safety,
  clean-install-provides-`warmline`, foreign-statusline protection, color
  gating, bars, histogram, encoding fallback, concentration math).

## [1.3.0] — 2026-08-19

### Added
- `warmline-audit --all`: audits every session under `~/.claude/projects`
  (or a directory you pass), one line per session plus a TOTAL — ranked by
  **avoidable cold tokens** (cold re-caches minus each session's unavoidable
  first write). `--price` adds the **estimated avoidable premium** in
  dollars, explicitly an estimate from recorded token counts, not billing
  data. `--json` gives the same machine-readable. Subagent transcripts and
  turnless sessions are excluded.
- Cold-cause attribution: cold turns (and compact-explained PARTIALs) are
  labeled `session start`, `/compact`, `auto-compact`, `model change`,
  `inactivity`, `inactivity+compact` (deliberately ambiguous), or `unknown`
  — read from structured `compact_boundary` markers and recorded models in
  the transcript, never guessed.
- README: Compatibility (transcript formats from Claude Code 2.1.181–2.1.233
  verified), Updating (re-running the installer is the update mechanism),
  manual Windows install steps.
- README translations: Japanese (`README.ja.md`), Traditional Chinese
  (`README.zh-TW.md`), Simplified Chinese (`README.zh-CN.md`), with a
  language switcher atop each.

### Changed
- Audit request dedup now prefers `message.id` over `requestId`, which some
  Claude Code versions omit on ~28% of assistant entries.
- Transcript parsing prefilters irrelevant lines: `--all` covers 149
  sessions / 353 MB in under a second on the reference machine.

## [1.2.0] — 2026-08-19

### Added
- ANSI colors in the statusline: green `HOT`, yellow `COLD(rebuilt)`, red
  `COLD(ttl?)` — what the hero image always showed, now real. Opt out with
  `NO_COLOR` or `WARMLINE_NO_COLOR`.
- Expiry countdown: when the cache is still warm but the idle gap is within
  15 minutes of the TTL, the line turns yellow and reads
  `cache HOT (cold in 9m)`.
- `warmline-audit --price <$/MTok>`: estimates in dollars what the cold
  re-caches cost over warm reads of the same tokens (and what the cache reads
  billed), in both text and `--json` output.
- CI: `test.sh` runs on every push via GitHub Actions.

### Fixed
- The idle clock now survives repaints: the session stamp stores a usage
  snapshot and only resets when the snapshot changes (a real API turn).
  Previously any statusline repaint reset the clock, so `COLD(ttl?)` could
  flip back to a stale `HOT` — an overnight-idle session showed `HOT` all
  night. A genuinely fresh turn is authoritative over the TTL inference.
- `gap` now means "minutes since this session's last API turn", not "since
  the previous render".

### Changed
- README: new "Coming back cold: `/compact`, `/clear`, or neither?" section —
  compaction benefits most on an already-cold cache, `/clear` is cheaper still
  when your state lives in memory/files, small contexts need nothing.

## [1.1.0] — 2026-08-19

### Added
- `warmline-audit`: grades every API turn of a past session transcript
  HOT / PARTIAL / COLD(rebuilt) / COLD(ttl) from its recorded usage fields —
  deterministic, after-the-fact verification instead of watching the
  statusline live. `--ttl` and `--json` flags.
- Hero image (`docs/statusline.svg`) showing the three statusline states.

### Changed
- README rewritten around measured findings instead of claims: the 1h TTL
  boundary (warm at 50 minutes idle, cold at 70), reads refresh the TTL,
  background task notifications keep the cache warm for free, host sleep
  defeats any wakeup, `/compact` always re-caches, and prefix stability
  matters as much as TTL. Keep-warm policy reframed accordingly, with a
  `/loop 50m` fallback where `ScheduleWakeup` is gated.

## [1.0.0] — 2026-08-18

Initial release: cache-aware statusline (`ctx % | cache HOT/COLD(rebuilt)/
COLD(ttl?) | gap Nm`) with per-session idle tracking, optional keep-warm
policy block for `~/.claude/CLAUDE.md`, installer with backup and
`--uninstall`, replay test suite.
