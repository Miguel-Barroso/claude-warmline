# Changelog

This project follows [semantic versioning](https://semver.org). The "public API"
is the statusline output, the CLI of `warmline-audit` and `install.sh`, and the
`WARMLINE_*` environment variables.

## [2.2.1] — 2026-09-02

Packaging and documentation only — no change to the statusline, the auditor, the
installer or the policy. `brew install` is one command again.

### Changed
- **Homebrew ships a cask, not a formula.** v2.2.0 shipped a formula, which left
  `brew install` doing half a job: it put the commands on your `PATH` and then
  told you to run `warmline setup` yourself — again after every `brew upgrade`,
  or the statusline silently stayed on the old version. A formula cannot do
  better. Its `post_install` hook runs under a sandbox whose rules include
  `deny_read_home`, so it cannot read `~/.claude`, let alone wire it; a probe
  formula writing to the real home produced `Warning: The post-install step did
  not complete successfully` and no file. Cask flight blocks are not sandboxed,
  so the cask's `postflight` runs `warmline setup` and its `uninstall_preflight`
  runs `warmline setup --remove` — *pre*flight, because the command has to still
  exist to undo its own wiring. Now:
  ```sh
  brew install   Miguel-Barroso/warmline/warmline   # installs and wires
  brew upgrade   warmline                           # re-wires at the new version
  brew uninstall warmline                           # unwires, then removes
  ```
  Nothing is done behind your back: it is the same `warmline setup`, it prints
  every file it touches, it backs up `settings.json`, and it still refuses to
  replace a statusline that isn't warmline's without `--force`. An uninstall
  leaves a keep-warm block in your `CLAUDE.md` alone and says so — removing text
  from a file you also write in is not an uninstaller's decision.
- **The cost, stated plainly: casks are macOS-only.** Homebrew on Linux has no
  cask support and will say so. Use the installer there — it is one command and
  does both halves itself, which is why this trade costs nothing the installer
  doesn't already cover.

### Documentation
- [`packaging/README.md`](packaging/README.md) rewritten around who wires Claude
  Code and why a formula can't, with the sandbox evidence and the cask release
  checklist. [docs/INSTALL.md](docs/INSTALL.md) and all four READMEs carry the
  one-command form.

## [2.2.0] — 2026-09-02

Warmline measured warmth accurately and then priced it with a number it made up.
This release removes the last invented figure: **no price sheet ships with
warmline any more**, the auditor solves your real rate from Claude Code's own
cost accounting, and the statusline stops showing only *state* and starts showing
*stake* — what a rebuild would cost, and how close the plan limit that actually
interrupts a subscription user is. Verified against Claude Code 2.1.252.

### Fixed
- **The 5-minute cache was billed as if it were the 1-hour one.** Every report
  applied a flat 1.9× premium — the 1h write/read spread. On the 5m bucket the
  spread is **1.15×**, so warmline overstated those sessions by ~65%. The
  multiplier is now per session, keyed on the bucket already accumulated from the
  transcript (1.9 for 1h, 1.15 for 5m, 1.9 when unknown), reported in the premium
  line and exposed as `premium_x` / `cache_bucket` in `--json`. **This moves
  published numbers downward**: a 5m session audited under 2.1.0 drops ~39%. The
  old figure was wrong; the new one is not a change of policy.
- **`ctx` warned at an invented 80%.** Auto-compact fires at
  `window − min(max_output, 20000) − 13000`, and every current model has
  `max_output ≥ 20000`, so the reserve is a flat 33k: 167,000 of a 200k window
  (83.5%), 967,000 of 1M (96.7%). A 1M-window session was painted yellow with
  800k of headroom left. The warning now tracks the real threshold, fires within
  10k of it, and **stays silent when auto-compact is off** —
  `DISABLE_AUTO_COMPACT` / `DISABLE_COMPACT` in the environment, or
  `autoCompactEnabled: false` in `settings.json`. `WARMLINE_CTX_WARN_PCT` still
  overrides; its default is now `auto`.

### Added
- **The stake, on the cache field**: `cache HOT (127k, cold ~11:58)`. The token
  count is `prompt_cache.recache_tokens_if_cold` — the size of the next cache
  write if this prefix dies — which the payload has carried all along and
  warmline ignored as "retrospective". It isn't: it is the only forward-looking
  number in the object, and it turns "is keeping this warm worth it?" from a
  feeling into arithmetic. Rendered inline, so the line gains no segment; omitted
  below 1000 tokens.
- **Plan limits**: `5h 78%`, or `7d 91%` — whichever window is nearer its cap,
  from `rate_limits`. Hidden below 50%, plain to 80%, yellow to 95%, red above,
  with the reset time `(14:20)` from `resets_at` once yellow. Dollars are not what interrupts a
  subscription user mid-task; this is. Absent for API keys, Bedrock and Vertex,
  where Claude Code sends no `rate_limits` and warmline shows nothing.
  `WARMLINE_NO_QUOTA` suppresses it.
- **Derived pricing — `warmline-audit --price` with no number.** Claude Code
  writes its own cost accounting to `~/.claude.json` (`lastCost` beside the token
  totals, per project). Every pricing tier in the shipped catalog bills the same
  multiples of its input price — output 5×, 1h cache write 2×, 5m write 1.25×,
  cache read 0.1× — so that solves for the effective input $/MTok exactly, with
  no price table at all, and it re-derives itself each session: switch from
  Sonnet to Opus and the number follows you. Across 11 projects on the
  development machine it lands between $1.99 and $4.86, with two pure-Sonnet
  projects at $3.00 and a Haiku-heavy one at $1.99 — the arithmetic checking
  itself against the published tiers.
- **`--all` prices each project at its own derived rate**, which is what makes a
  mixed Opus/Sonnet history honest, and every report names where its number came
  from (`derived` / `flag` / `assumed`, also in `--json` as `price_source`).
- **`warmline-audit --cold-at`** prints the epoch second and clock time this
  session's cache is due to expire — one line, for scripts.
- **`warmline setup`** — the wiring half of `install.sh` as its own command:
  installs the statusline, wires `settings.json` (same backup, same refusal to
  replace a foreign statusline without `--force`, same `refreshInterval`, same
  keep-warm block refresh), and `--remove` takes it all back out. It exists so a
  package manager can own its prefix and nothing else: **no formula should edit
  your `~/.claude/settings.json`**. Finds its data files beside the command or
  in `../share/warmline`, following symlinks; `WARMLINE_SHARE_DIR` overrides.
- **Homebrew**: `brew install Miguel-Barroso/warmline/warmline`. The formula
  lives in [`packaging/homebrew/warmline.rb`](packaging/homebrew/warmline.rb) and
  is published to the [`Miguel-Barroso/homebrew-warmline`](https://github.com/Miguel-Barroso/homebrew-warmline)
  tap rather than homebrew-core — core wants a
  notability this project hasn't earned and would gate every release on its
  review cadence. `brew install …/warmline && warmline setup`, and `brew test`
  runs the real setup against a scratch `CLAUDE_CONFIG_DIR`, so it proves the
  prefix layout resolves without touching the tester's own config. Built,
  installed, tested and `brew style`-clean from a local tap before shipping.
  [`packaging/README.md`](packaging/README.md) has the release checklist.
- **`install.sh` downloads with curl *or* wget**, whichever is on the machine,
  and the front page offers both one-liners. Minimal Linux images ship one or
  the other; until now a wget-only box could fetch the installer and then watch
  it fail on its own first download.
- **`warmline wait-for --until-cold`** returns when the cache deadline is near
  (detected TTL minus a 2-minute margin) as well as when the target finishes,
  whichever comes first: exit 0 for the target, 3 for the deadline, 2 for
  misuse. A job that ends at minute 12 now costs zero pings instead of one every
  50 minutes, and the wait self-terminates instead of relying on the agent to
  count re-arms. Usable alone, with no target, as a plain "wake me before it goes
  cold".

### Changed
- **The keep-warm policy triggers on stake, not on context percentage.** "Context
  above roughly 30%" was a proxy for a quantity now printed on the statusline, and
  a bad one at 1M windows. It reads the cache field's token figure instead
  (~50k+). New skip clause: **5-minute-TTL sessions are never worth pinging** —
  holding one warm needs ~12 pings an hour against a 1.15× premium, and
  break-even is ~11.5. The auto-compact clause now points at the real 33k
  reserve, and `wait-for --until-cold` is preferred over a scheduled ping
  wherever the wait is locally observable. 441 words, up from 440: the two new
  rules were paid for by tightening, not by growth. **If you already have keep-warm
  on**, upgrading rewrites the block in your `CLAUDE.md` in place (verified on a
  v2.1.0 → v2.2.0 upgrade, with the rest of the file untouched) — unless you
  edited it, in which case it is left alone and the console tells you the wording
  moved on. `warmline keep-warm status` shows which case you are in.
- **`--price N` still wins**, and the hardcoded $3 survives only as an
  explicitly labelled `ASSUMED (Sonnet tier)` fallback when no ledger is
  readable. Rates print as `$15`, not `$15.00`, and `$4.17`, not `$4.166667`.

### Documentation
- [docs/MEASUREMENTS.md](docs/MEASUREMENTS.md) gains the seven-tier ratio table,
  the `window − 33000` derivation, and the price-derivation method with the
  11-project spread. The eight-week audit is re-run at derived per-project rates:
  130 sessions, ~$63.
- [docs/INSTALL.md](docs/INSTALL.md) gains a package-manager section, the wget
  one-liner, and a config table caught up with this release (`WARMLINE_NO_QUOTA`,
  `WARMLINE_SHARE_DIR`, `WARMLINE_CTX_WARN_PCT` now `auto`).
- [docs/STATUSLINE.md](docs/STATUSLINE.md), [docs/AUDIT.md](docs/AUDIT.md) and
  [docs/KEEP-WARM.md](docs/KEEP-WARM.md) cover the stake, plan limits, the new
  `ctx` behaviour, price provenance, the premium correction and `--until-cold`.
  README and the Japanese, 繁體中文 and 简体中文 translations mirror all of it.
- Tests: 83 → 98, 0 failed. The suite is now hermetic with respect to pricing —
  a synthetic `.claude.json` whose arithmetic solves to round rates, plus a
  no-ledger case that pins the `ASSUMED` label.

### Explicitly not added
- **"Keep-warm saved you $X".** Keep-warm state is not recoverable per session —
  `~/.claude/CLAUDE.md` lives in the system prompt, which Claude Code never
  serialises (checked across 372 transcripts). Any savings figure would be
  inference dressed as measurement, which is what 2.0.0 removed. An honest
  exposure number is the same answer without the invention.

## [2.1.0] — 2026-09-01

The first release whose own install command names it. Everything here is the
installer and the front page; the statusline, the auditor and keep-warm are
unchanged.

### Added
- **`install.sh --ref TAG` (and `WARMLINE_REF`)** installs one tag or branch
  instead of main's tip. Until now `REPO_RAW` was hard-wired to `main`, so
  "install v1.8.0" and "install main" were the same command and a release page
  claiming otherwise was overselling — the tag in the URL only ever pinned the
  installer, while the four files it downloads came from the tip. **Release
  pages now link their own tag**, which is what a version number is for. A
  pinned install always fetches, even from a checkout: the tree you are standing
  in is not the tag you asked for. Bad refs are refused before anything is
  touched, and a fetch that fails leaves the copy already installed intact —
  downloads land beside the target, not on it.

### Changed
- **The README's install block holds the install line and nothing else.** The
  four `warmline` commands under it shared one code fence, so the copy button
  handed you a one-liner with three commands and a `watch` stapled to it. They
  are a table now, one command per row.
- **README and repository description repositioned around the cache, not the
  statusline.** "Another customizable statusline" is a crowded category and the
  wrong one: what warmline shows is whether your context is still being reused.
  The page now opens on that, puts install above the architecture, adds "Why
  warmline" and "Local by design", and states the data boundary plainly —
  warmline observes what Claude Code exposes locally, with no privileged access
  to anything. Documentation only; no behavior, commands or claims changed.
  Mirrored into the Japanese, 繁體中文 and 简体中文 READMEs.

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
