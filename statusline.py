#!/usr/bin/env python3
"""claude-warmline statusline for Claude Code.

Renders one line:

    Fable 5 | my-project | ctx 43% (168k) | cache HOT (cold ~13:04) | gap 12m | keep-warm on

Cache verdict (colored green/yellow/red unless NO_COLOR or
WARMLINE_NO_COLOR is set):
  HOT (cold ~13:04)  the previous request read from the prompt cache; the
                  absolute wall-clock expiry makes the line stale-proof --
                  even a frozen repaint read hours later tells the truth
  HOT (cold in Nm)  still warm, but the idle gap is within 15 minutes of
                  the TTL -- ping or come back now, or pay the rebuild
  COLD(rebuilt)   the previous request wrote the cache without reading it
                  (the prefix was cold and has just been re-cached)
  COLD(ttl?)      inferred: this session has been quiet for longer than the
                  cache TTL, so the prefix has expired regardless of what
                  the stale usage fields say
  ?               usage fields unavailable

The installer wires statusLine.refreshInterval (60s) into settings.json,
so Claude Code re-runs this script while the session idles and COLD(ttl?)
appears within a minute of the TTL passing -- no more stale HOT. That
refresh runs this local script only: it never talks to the API, costs
nothing, and does not keep the cache warm. On Claude Code versions without
refreshInterval the line is event-driven and can freeze; the absolute
expiry time in the HOT verdict keeps even a frozen line honest.

The usage numbers Claude Code passes to the statusline describe the
PREVIOUS request, so HOT/COLD(rebuilt) are authoritative but lag one
turn; COLD(ttl?) is a time inference and is marked with a "?".

The keep-warm field reports whether the optional keep-warm policy is
installed, read from the real CLAUDE.md on every render (never a state
file), matching `warmline keep-warm status`:

  keep-warm on    the marker-delimited policy block is in CLAUDE.md (green)
  keep-warm off   it is not (dim)
  keep-warm ?     one marker without its pair -- a malformed block that the
                  agent may read as truncated policy (yellow); fix with
                  `warmline keep-warm off && warmline keep-warm on`

"on" means the policy is installed, not that a ping is scheduled: it is an
instruction the agent follows during long waits, and `warmline-audit` is
how you check whether it actually worked.

The gap is measured per session via a stamp file that stores the last-seen
usage snapshot; its mtime moves only when the snapshot changes -- i.e. when
an API turn actually happened -- so repaints of an idle session don't reset
the clock, and COLD(ttl?) appears (and persists) on the next repaint after
the TTL passes. Concurrent sessions don't reset each other's clock.

Configuration (environment variables):
  WARMLINE_TTL_MIN    prompt-cache TTL in minutes. Unset, the TTL is
                      auto-detected from the transcript's last cache write
                      (usage entries record the ephemeral_5m/1h bucket),
                      falling back to 60
  WARMLINE_STATE_DIR  stamp-file directory (default ~/.claude/warmline-state)
  WARMLINE_NO_COLOR   if set (or NO_COLOR), plain output without ANSI colors
  WARMLINE_NO_KEEPWARM  if set, omit the keep-warm field
  WARMLINE_DEBUG      if set, keep the last raw statusline payload in
                      $WARMLINE_STATE_DIR/last-payload.json for inspection
  CLAUDE_CONFIG_DIR   Claude Code's config directory (default ~/.claude);
                      its CLAUDE.md is where the keep-warm block lives
"""
import json
import os
import sys
import time

TTL_MIN = float(os.environ.get("WARMLINE_TTL_MIN", "60"))
STATE_DIR = os.path.expanduser(
    os.environ.get("WARMLINE_STATE_DIR", "~/.claude/warmline-state")
)
STAMP_MAX_AGE_DAYS = 7
EXPIRY_WARN_MIN = 15

CLAUDE_DIR = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")
KW_BEGIN = "<!-- >>> claude-warmline keep-warm >>> -->"
KW_END = "<!-- <<< claude-warmline keep-warm <<< -->"
SHOW_KEEPWARM = not os.environ.get("WARMLINE_NO_KEEPWARM")

GREEN, YELLOW, RED, DIM, RESET = (
    "\033[32m", "\033[33m", "\033[31m", "\033[2m", "\033[0m"
)
COLOR = not (os.environ.get("NO_COLOR") or os.environ.get("WARMLINE_NO_COLOR"))


def paint(text, color):
    return color + text + RESET if COLOR else text


def keep_warm_state():
    """'on' | 'off' | '?', from the same markers `warmline keep-warm` writes.

    Read from CLAUDE.md itself on every render, so hand-editing the file is
    reflected immediately; one marker without its pair is a malformed block
    and reported as unknown rather than as a confident on/off.
    """
    try:
        with open(os.path.join(CLAUDE_DIR, "CLAUDE.md")) as f:
            text = f.read()
    except OSError:
        return "off"
    begin, end = KW_BEGIN in text, KW_END in text
    if begin and end:
        return "on"
    return "?" if begin or end else "off"


def sniff_ttl(transcript_path):
    """TTL in minutes from the transcript's last cache write, or None.

    Transcript usage entries record which bucket a cache write went to
    (cache_creation.ephemeral_5m/1h_input_tokens); the statusline payload
    doesn't carry that, so peek at the transcript tail.
    """
    if not transcript_path:
        return None
    try:
        with open(transcript_path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 65536))
            tail = f.read().decode("utf-8", "replace")
    except OSError:
        return None
    for line in reversed(tail.splitlines()):
        if '"ephemeral_5m_input_tokens"' not in line:
            continue
        try:
            e = json.loads(line)
        except ValueError:
            continue  # the 64k window can start mid-line
        if not isinstance(e, dict):
            continue
        cc = ((e.get("message") or {}).get("usage") or {}).get("cache_creation") or {}
        e5 = cc.get("ephemeral_5m_input_tokens") or 0
        e1 = cc.get("ephemeral_1h_input_tokens") or 0
        if e5 or e1:
            return 5 if e5 > e1 else 60
    return None


def session_state(session_id, snapshot, raw):
    """(minutes since this session's last API turn or None, fresh_turn).

    The stamp is rewritten -- resetting its mtime -- only when the usage
    snapshot differs from the stored one. fresh_turn is True when a change
    was seen against a previous snapshot: the usage fields are then current,
    not stale, and take precedence over the TTL inference.
    """
    gap, fresh = None, False
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        stamp = os.path.join(STATE_DIR, session_id + ".stamp")
        prev = None
        try:
            gap = (time.time() - os.path.getmtime(stamp)) / 60
            with open(stamp) as f:
                prev = f.read()
        except OSError:
            pass
        if prev != snapshot:
            fresh = prev is not None
            with open(stamp, "w") as f:
                f.write(snapshot)
        if os.environ.get("WARMLINE_DEBUG"):
            with open(os.path.join(STATE_DIR, "last-payload.json"), "w") as f:
                f.write(raw)
        cutoff = time.time() - STAMP_MAX_AGE_DAYS * 86400
        for name in os.listdir(STATE_DIR):
            path = os.path.join(STATE_DIR, name)
            try:
                if os.path.getmtime(path) < cutoff:
                    os.remove(path)
            except OSError:
                pass
    except OSError:
        pass
    return gap, fresh


def main():
    raw = sys.stdin.read()
    try:
        d = json.loads(raw)
    except ValueError:
        print("warmline: bad input")
        return

    cw = d.get("context_window") or {}
    usage = cw.get("current_usage") or {}
    cache_read = usage.get("cache_read_input_tokens") or 0
    cache_creation = usage.get("cache_creation_input_tokens") or 0
    snapshot = json.dumps(
        [cache_read, cache_creation, cw.get("total_input_tokens"),
         usage.get("input_tokens")]
    )

    session = str(d.get("session_id") or "default")
    session = "".join(c for c in session if c.isalnum() or c in "-_") or "default"
    gap_min, fresh = session_state(session, snapshot, raw)

    if gap_min is None:
        tp = d.get("transcript_path")
        if tp and os.path.exists(tp):
            gap_min = (time.time() - os.path.getmtime(tp)) / 60

    model = (d.get("model") or {}).get("display_name") or (d.get("model") or {}).get("id") or "?"
    ws = d.get("workspace") or {}
    cwd = os.path.basename(ws.get("current_dir") or d.get("cwd") or "") or "?"

    ttl_min = TTL_MIN
    if "WARMLINE_TTL_MIN" not in os.environ:
        ttl_min = sniff_ttl(d.get("transcript_path")) or TTL_MIN

    # a fresh turn just reset the clock, so the full TTL lies ahead; the
    # stamp's mtime (which gap_min was read from) predates the reset
    remaining = ttl_min if fresh else (
        None if gap_min is None else ttl_min - gap_min)
    warn_min = min(EXPIRY_WARN_MIN, ttl_min / 2)
    if not fresh and remaining is not None and remaining <= 0:
        cache = paint("cache COLD(ttl?)", RED)
    elif cache_read > 0:
        if remaining is None:
            cache = paint("cache HOT", GREEN)
        elif not fresh and remaining <= warn_min:
            cache = paint("cache HOT (cold in %dm)" % max(1, round(remaining)), YELLOW)
        else:
            # absolute wall-clock expiry: stale-proof on harnesses that
            # never repaint an idle line
            cold_at = time.strftime(
                "%H:%M", time.localtime(time.time() + remaining * 60))
            cache = paint("cache HOT (cold ~%s)" % cold_at, GREEN)
    elif cache_creation > 0:
        cache = paint("cache COLD(rebuilt)", YELLOW)
    else:
        cache = paint("cache ?", DIM)

    parts = [model, cwd]

    pct = cw.get("used_percentage")
    tokens = cw.get("total_input_tokens")
    try:
        ctx = f"ctx {round(float(pct))}%"
        if tokens:
            ctx += f" ({round(tokens / 1000)}k)"
        parts.append(ctx)
    except (TypeError, ValueError):
        pass

    parts.append(cache)

    if gap_min is not None and gap_min >= 5:
        parts.append(f"gap {int(gap_min)}m")

    if SHOW_KEEPWARM:
        kw = keep_warm_state()
        parts.append(paint("keep-warm " + kw,
                           {"on": GREEN, "off": DIM}.get(kw, YELLOW)))

    print(" | ".join(parts))


if __name__ == "__main__":
    main()
