#!/usr/bin/env python3
"""claude-warmline statusline for Claude Code.

Renders one line:

    Fable 5 | my-project | ctx 43% (168k) | cache HOT (cold ~13:04)

The cache verdict comes entirely from the `prompt_cache` object Claude Code
puts on stdin (v2.1.251+). warmline does not infer cache state: it does not
read the transcript, does not keep a stamp file, and does not time the gap
between turns. Claude Code owns the truth; this script owns the display.

  cache HOT (cold ~13:04)  the cached prefix is warm and leaves its TTL at
                  the wall-clock time shown. Absolute, not a countdown, so a
                  line frozen on screen for hours still reads truthfully.
                  Yellow within EXPIRY_WARN_MIN of the expiry -- same text,
                  colour only, so nothing shifts width as the moment nears
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

The statistics Claude Code also offers here -- hit_ratio, misses,
requests, recache_tokens_if_cold -- are deliberately not shown. They are
retrospective, they name no action you can take mid-session, and `/usage`
already prints them on demand. `warmline audit` is where history belongs.

The ctx field turns yellow past WARMLINE_CTX_WARN_PCT (default 80) because
auto-compaction -- measured firing around 84% of the window -- rewrites the
prefix and voids the cache without being asked. Near the line, a wait isn't
worth keeping warm: the prefix is about to be replaced anyway.

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
  WARMLINE_CTX_WARN_PCT  context-window percentage at which the ctx field
                      turns yellow (default 80; 0 or less disables it)
  CLAUDE_CONFIG_DIR   Claude Code's config directory (default ~/.claude);
                      its CLAUDE.md is where the keep-warm block lives
"""
import json
import os
import re
import sys
import time

# how close to expiry the HOT verdict turns yellow. Capped at half the TTL,
# so the 5-minute bucket doesn't spend its whole life in warning colours.
EXPIRY_WARN_MIN = 15
TTL_MINUTES = {"5m": 5.0, "1h": 60.0}

CLAUDE_DIR = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")
KW_BEGIN = "<!-- >>> claude-warmline keep-warm >>> -->"
KW_END = "<!-- <<< claude-warmline keep-warm <<< -->"
SHOW_KEEPWARM = not os.environ.get("WARMLINE_NO_KEEPWARM")
try:
    CTX_WARN_PCT = float(os.environ.get("WARMLINE_CTX_WARN_PCT", "80"))
except ValueError:
    CTX_WARN_PCT = 80.0

GREEN, YELLOW, RED, DIM, RESET = (
    "\033[32m", "\033[33m", "\033[31m", "\033[2m", "\033[0m"
)
COLOR = not (os.environ.get("NO_COLOR") or os.environ.get("WARMLINE_NO_COLOR"))


def paint(text, color):
    return color + text + RESET if COLOR else text


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

    expires_at = prompt_cache.get("expires_at")
    if not isinstance(expires_at, (int, float)) or isinstance(expires_at, bool):
        return "cache HOT" + badge, GREEN  # warm, but no usable expiry

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
    text = "cache HOT%s (cold ~%s)" % (badge, cold_at)
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
    try:
        pct = float(pct)
        ctx = f"ctx {round(pct)}%"
        if tokens:
            ctx += f" ({round(tokens / 1000)}k)"
        # auto-compaction is the one prefix rewrite nobody chooses; it fires
        # near the top of the window, so a high ctx is the only warning of it
        parts.append(paint(ctx, YELLOW) if 0 < CTX_WARN_PCT <= pct else ctx)
    except (TypeError, ValueError):
        pass

    text, color = cache_field(d.get("prompt_cache"), time.time())
    parts.append(paint(text, color))

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
