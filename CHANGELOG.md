# Changelog

This project follows [semantic versioning](https://semver.org). The "public API"
is the statusline output, the CLI of `warmline-audit` and `install.sh`, and the
`WARMLINE_*` environment variables.

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
