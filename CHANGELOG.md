# Changelog

This project follows [semantic versioning](https://semver.org). The "public API"
is the statusline output, the CLI of `warmline-audit` and `install.sh`, and the
`WARMLINE_*` environment variables.

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
