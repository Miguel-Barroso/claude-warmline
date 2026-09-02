#!/usr/bin/env python3
"""claude-warmline statusline for Claude Code.

Renders one line:

    Fable 5 | my-project | ctx 43% (168k) | cache HOT (127k, cold ~13:04)

The cache verdict comes entirely from the `prompt_cache` object Claude Code
puts on stdin (v2.1.251+). warmline does not infer cache state: it does not
read the transcript, does not keep a stamp file, and does not time the gap
between turns. Claude Code owns the truth; this script owns the display.

  cache HOT (127k, cold ~13:04)  the cached prefix is warm; 127k is what the
                  next turn would have to re-cache if it went cold
                  (recache_tokens_if_cold), and the wall-clock time is when
                  the TTL runs out. Absolute, not a countdown, so a line
                  frozen on screen for hours still reads truthfully. Yellow
                  within EXPIRY_WARN_MIN of the expiry -- same text, colour
                  only, so nothing shifts width as the moment nears
  cache HOT 5m    as above, on the 5-minute TTL. The badge appears only for
                  the short bucket: usage credits, an API key, a cloud
                  provider. The 1-hour case is the norm and goes unlabelled,
                  because a field that never changes is not worth reading
  cache COLD      the prefix is outside its TTL; the next turn re-caches it
  cache off       caching_observed is false -- prompt caching is off, or this
                  provider or gateway never reports cache tokens. Not a
                  failure to wait out: nothing here will warm up
  cache ?         no prompt_cache object. Claude Code before v2.1.251, or
                  before the main conversation's first API response

`cache COLD`, `cache off` and `cache ?` are three different facts and are
deliberately not collapsed: "the cache expired", "caching is not happening"
and "warmline cannot see" call for different responses, and guessing between
them is how a cache gauge starts lying.

The stake is the one prospective number in the payload, and it is the whole
decision: a cold rebuild bills the 1-hour bucket at ~2x base input against a
warm read's ~0.1x, so 127k warm is ~1.9 x 127k input-tokens of avoidable
premium -- in any currency, on any model, since every Claude pricing tier
uses those same multiples. The retrospective statistics Claude Code also
offers here -- hit_ratio, misses, requests -- stay hidden: they name no
action you can take now, `/usage` prints them on demand, and
`warmline audit` is where history belongs.

The ctx field turns yellow as auto-compaction comes into range, because that
is the one prefix rewrite nobody chooses and it voids the cache without
asking. The threshold is not a guess: Claude Code compacts at
`window - min(max_output, 20000) - 13000`, and every current model has a
max_output of at least 20000, so the reserve is a flat 33k -- 167k of a 200k
window, 967k of a 1M one. The field goes quiet entirely when auto-compact
cannot fire (DISABLE_AUTO_COMPACT / DISABLE_COMPACT in the environment, or
`autoCompactEnabled: false` in settings), and follows `autoCompactWindow` /
CLAUDE_CODE_AUTO_COMPACT_WINDOW when either moves the window.

The quota field is the currency a subscription user actually feels, from the
`rate_limits` Claude Code sends when plan limits apply (absent on API keys,
Bedrock and Vertex, where nothing is shown):

  5h 62%          the window nearest its cap -- `5h`, `7d` or `spend` --
                  hidden below QUOTA_SHOW_PCT, because a quota with room to
                  spare is not news
  5h 91% (14:20)  yellow past QUOTA_WARN_PCT, red past QUOTA_CRIT_PCT, and
                  from there it also says when the window resets, which is
                  the only fact that changes what you do about it

The keep-warm field appears only when something is wrong with it, read from
the real CLAUDE.md on every render (never a state file):

  keep-warm on*   installed, but the block no longer matches
                  warmline-keep-warm.md -- an older release's wording, or a
                  hand edit, so the agent is following superseded
                  instructions; refresh with
                  `warmline keep-warm off && warmline keep-warm on`
  keep-warm ?     one marker without its pair -- a malformed block that the
                  agent may read as truncated policy; same fix

A correctly installed policy renders nothing. `warmline keep-warm status`
answers "is it on"; a statusline field that has read the same green `on` for
three months is wallpaper, and next to a red `cache COLD` it reads as a
contradiction.

Configuration (environment variables):
  WARMLINE_NO_COLOR   if set (or NO_COLOR), plain output without ANSI colors
  WARMLINE_NO_KEEPWARM  if set, never show the keep-warm field
  WARMLINE_NO_QUOTA   if set, never show the rate-limit field
  WARMLINE_CTX_WARN_PCT  fixed context-window percentage at which the ctx
                      field turns yellow, replacing the auto-compact
                      threshold above (0 or less disables the warning)
  CLAUDE_CONFIG_DIR   Claude Code's config directory (default ~/.claude);
                      its CLAUDE.md is where the keep-warm block lives, and
                      its settings.json is read for the auto-compact keys
"""
import datetime
import json
import os
import re
import sys
import time

# how close to expiry the HOT verdict turns yellow. Capped at half the TTL,
# so the 5-minute bucket doesn't spend its whole life in warning colours.
EXPIRY_WARN_MIN = 15
TTL_MINUTES = {"5m": 5.0, "1h": 60.0}

# below this the stake isn't worth the width -- nothing is at risk yet
STAKE_MIN_TOKENS = 1000

# Claude Code compacts at window - min(model max_output, 20000) - 13000.
# The cap makes the subtrahend a constant for every current model (all are
# at or above 20000 max output tokens), so the reserve needs no catalog.
AUTOCOMPACT_RESERVE = 33000
# how far ahead of that line the ctx field starts warning
AUTOCOMPACT_WARN_TOKENS = 10000

# quota windows: silent while there's room, yellow when it starts to bind,
# red when it's about to stop being an abstraction
QUOTA_SHOW_PCT, QUOTA_WARN_PCT, QUOTA_CRIT_PCT = 50, 80, 95

CLAUDE_DIR = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")
KW_BEGIN = "<!-- >>> claude-warmline keep-warm >>> -->"
KW_END = "<!-- <<< claude-warmline keep-warm <<< -->"
SHOW_KEEPWARM = not os.environ.get("WARMLINE_NO_KEEPWARM")
SHOW_QUOTA = not os.environ.get("WARMLINE_NO_QUOTA")
try:
    # unset means "use the real auto-compact threshold"; a number pins it
    CTX_WARN_PCT = float(os.environ["WARMLINE_CTX_WARN_PCT"])
except (KeyError, ValueError):
    CTX_WARN_PCT = None

GREEN, YELLOW, RED, DIM, RESET = (
    "\033[32m", "\033[33m", "\033[31m", "\033[2m", "\033[0m"
)
COLOR = not (os.environ.get("NO_COLOR") or os.environ.get("WARMLINE_NO_COLOR"))


def paint(text, color):
    return color + text + RESET if COLOR else text


def fmt_tokens(n):
    """127000 -> '127k', 1240000 -> '1.2M'. Two significant places at most:
    this is a magnitude to react to, not an accounting figure."""
    if n >= 999500:
        return ("%.1f" % (n / 1e6)).rstrip("0").rstrip(".") + "M"
    return "%dk" % round(n / 1000.0)


def env_off(name):
    """True when an env var is set to something Claude Code reads as on.
    Empty, '0' and 'false' are the documented ways to leave one inert."""
    v = os.environ.get(name)
    return v is not None and v.strip().lower() not in ("", "0", "false")


def load_settings(project_dir):
    """User settings under the config dir, overlaid with the project's own.

    A shallow top-level merge in Claude Code's own precedence order, which is
    all the two scalar keys read here need. Missing or malformed files are
    simply absent -- a settings file this script cannot parse must never cost
    anyone their statusline.
    """
    paths = [os.path.join(CLAUDE_DIR, "settings.json")]
    if project_dir:
        paths += [os.path.join(project_dir, ".claude", "settings.json"),
                  os.path.join(project_dir, ".claude", "settings.local.json")]
    merged = {}
    for p in paths:
        try:
            with open(p) as f:
                d = json.load(f)
        except (OSError, ValueError):
            continue
        if isinstance(d, dict):
            merged.update(d)
    return merged


def autocompact_limit(window, settings):
    """Token count at which auto-compact rewrites the prefix, or None when it
    can't fire at all -- disabled by env or settings, or no usable window.

    None is a real answer, not a failure: with auto-compact off there is no
    line to warn about, and a warning about a threshold that cannot be
    reached is exactly the invented number this replaced.
    """
    if env_off("DISABLE_AUTO_COMPACT") or env_off("DISABLE_COMPACT"):
        return None
    if settings.get("autoCompactEnabled") is False:
        return None
    w = (os.environ.get("CLAUDE_CODE_AUTO_COMPACT_WINDOW")
         or settings.get("autoCompactWindow") or window)
    try:
        w = float(w)
    except (TypeError, ValueError):
        return None
    return w - AUTOCOMPACT_RESERVE if w > AUTOCOMPACT_RESERVE else None


def fmt_reset(resets_at):
    """'14:20' from an epoch or an ISO 8601 string, '' from anything else.
    Both shapes are in the wild; neither is worth a wrong time on screen."""
    if isinstance(resets_at, bool):
        return ""
    if isinstance(resets_at, (int, float)):
        return time.strftime("%H:%M", time.localtime(resets_at))
    if isinstance(resets_at, str):
        try:
            t = datetime.datetime.fromisoformat(resets_at.replace("Z", "+00:00"))
        except ValueError:
            return ""
        return t.astimezone().strftime("%H:%M")
    return ""


def quota_field(rate_limits):
    """(text, color) for the plan window nearest its cap, or None.

    Only one window is shown -- the binding one. Two percentages side by side
    ask the reader to do the comparison the field exists to do for them.
    """
    if not isinstance(rate_limits, dict):
        return None                        # API key, Bedrock, Vertex: no plan
    best = None
    for key, label in (("five_hour", "5h"), ("seven_day", "7d"),
                       ("spend_limit", "spend")):
        w = rate_limits.get(key)
        if not isinstance(w, dict):
            continue
        try:
            p = float(w.get("used_percentage"))
        except (TypeError, ValueError):
            continue
        if best is None or p > best[0]:
            best = (p, label, w.get("resets_at"))
    if best is None or best[0] < QUOTA_SHOW_PCT:
        return None
    p, label, resets = best
    text = "%s %d%%" % (label, round(p))
    if p < QUOTA_WARN_PCT:
        return text, None
    when = fmt_reset(resets)
    return text + (" (%s)" % when if when else ""), \
        RED if p >= QUOTA_CRIT_PCT else YELLOW


def keep_warm_state():
    """'on' | 'stale' | 'off' | '?', from the markers `warmline keep-warm` writes.

    Read from CLAUDE.md itself on every render, so hand-editing the file is
    reflected immediately; one marker without its pair is a malformed block
    and reported as unknown rather than as a confident on/off.

    'stale' is the case a plain on/off hides: the block is installed but no
    longer matches warmline-keep-warm.md, so an upgrade left the agent
    reading a previous release's policy. Same normalized comparison
    `warmline keep-warm status` reports as `policy modified`.
    """
    try:
        with open(os.path.join(CLAUDE_DIR, "CLAUDE.md")) as f:
            text = f.read()
    except OSError:
        return "off"
    begin, end = KW_BEGIN in text, KW_END in text
    if not (begin and end):
        return "?" if begin or end else "off"
    try:
        with open(os.path.join(CLAUDE_DIR, "warmline-keep-warm.md")) as f:
            policy = f.read()
    except OSError:
        return "on"  # no installed policy to compare against; don't cry wolf
    body = text.split(KW_BEGIN, 1)[1].split(KW_END, 1)[0]
    norm = lambda s: re.sub(r"\s+", " ", s).strip()  # noqa: E731
    return "on" if norm(body) == norm(policy) else "stale"


def cache_field(prompt_cache, now):
    """(text, color) for the cache verdict, from the authoritative object.

    Gated on the shape of the payload rather than on the reported Claude Code
    version: any build that sends a usable `prompt_cache` gets the real
    verdict, and any build that doesn't gets `?`. Nothing here falls back to
    guessing, because a confident wrong verdict is worse than an honest "?".
    """
    if not isinstance(prompt_cache, dict):
        return "cache ?", DIM              # pre-2.1.251, or pre-first-response

    if prompt_cache.get("caching_observed") is False:
        return "cache off", DIM            # nothing to wait for

    # `warm` is the only warmth signal, checked before the clock on purpose:
    # at expiry Claude Code flips it to false but leaves `expires_at` at its
    # old value rather than nulling it (observed on 2.1.252).
    warm = prompt_cache.get("warm")
    if warm is False:
        return "cache COLD", RED
    if warm is not True:
        return "cache ?", DIM              # object present but unusable

    ttl = prompt_cache.get("ttl")
    badge = " 5m" if ttl == "5m" else ""   # anomaly only; 1h is the norm

    # what going cold would cost: the tokens the next turn would re-cache.
    # Claude Code computes it; small stakes are dropped rather than shown,
    # since a rebuild of a few hundred tokens is not a thing to act on.
    stake = prompt_cache.get("recache_tokens_if_cold")
    if isinstance(stake, bool) or not isinstance(stake, (int, float)) \
            or stake < STAKE_MIN_TOKENS:
        stake = None

    expires_at = prompt_cache.get("expires_at")
    if not isinstance(expires_at, (int, float)) or isinstance(expires_at, bool):
        # warm, but no usable expiry -- the stake still stands on its own
        text = "cache HOT" + badge
        return (text + " (%s)" % fmt_tokens(stake) if stake else text), GREEN

    remaining_min = (expires_at - now) / 60
    if remaining_min <= 0:
        # The authoritative expiry has passed while `warm` still claims true.
        # Claude Code re-runs this script at expires_at (verified on 2.1.252),
        # so normally the flip has already arrived; this covers a repaint that
        # the trigger couldn't deliver, such as one slept through.
        return "cache COLD", RED

    # yellow for the final EXPIRY_WARN_MIN, but never for more than half the
    # TTL: 15 minutes of an hour, 2.5 of five. An unrecognised ttl string is
    # left uncapped rather than guessed at, since assuming a short TTL would
    # paint most of a long one yellow.
    ttl_min = TTL_MINUTES.get(ttl)
    warn_min = EXPIRY_WARN_MIN if ttl_min is None else min(EXPIRY_WARN_MIN, ttl_min / 2)
    cold_at = time.strftime("%H:%M", time.localtime(expires_at))
    inside = ("%s, cold ~%s" % (fmt_tokens(stake), cold_at)) if stake \
        else "cold ~%s" % cold_at
    text = "cache HOT%s (%s)" % (badge, inside)
    return text, YELLOW if remaining_min <= warn_min else GREEN


def main():
    raw = sys.stdin.read()
    try:
        d = json.loads(raw)
    except ValueError:
        print("warmline: bad input")
        return

    model = (d.get("model") or {}).get("display_name") or (d.get("model") or {}).get("id") or "?"
    ws = d.get("workspace") or {}
    cwd = os.path.basename(ws.get("current_dir") or d.get("cwd") or "") or "?"
    parts = [model, cwd]

    cw = d.get("context_window") or {}
    pct = cw.get("used_percentage")
    tokens = cw.get("total_input_tokens")
    window = cw.get("context_window_size")
    try:
        pct = float(pct)
        ctx = f"ctx {round(pct)}%"
        if tokens:
            ctx += f" ({round(tokens / 1000)}k)"
        # auto-compaction is the one prefix rewrite nobody chooses; it fires
        # at a threshold Claude Code computes from the window, so warn against
        # that line rather than a round number that resembles it
        if CTX_WARN_PCT is not None:
            warn = 0 < CTX_WARN_PCT <= pct
        else:
            limit = autocompact_limit(window, load_settings(ws.get("project_dir")))
            used = tokens if tokens else (pct / 100.0 * window if window else None)
            warn = bool(limit and used and used >= limit - AUTOCOMPACT_WARN_TOKENS)
        parts.append(paint(ctx, YELLOW) if warn else ctx)
    except (TypeError, ValueError):
        pass

    text, color = cache_field(d.get("prompt_cache"), time.time())
    parts.append(paint(text, color))

    if SHOW_QUOTA:
        quota = quota_field(d.get("rate_limits"))
        if quota:
            parts.append(paint(quota[0], quota[1]) if quota[1] else quota[0])

    if SHOW_KEEPWARM:
        kw = keep_warm_state()
        # only the states that need doing something about: a correct policy
        # and a deliberate absence are both silent
        if kw in ("stale", "?"):
            label = "on*" if kw == "stale" else "?"
            parts.append(paint("keep-warm " + label, YELLOW))

    print(" | ".join(parts))


if __name__ == "__main__":
    main()
