#!/usr/bin/env python3
"""claude-warmline statusline for Claude Code.

Renders one line:

    Fable 5 | my-project | ctx 43% (168k) | cache HOT | gap 12m

Cache verdict:
  HOT            the previous request read from the prompt cache
  COLD(rebuilt)  the previous request wrote the cache without reading it
                 (the prefix was cold and has just been re-cached)
  COLD(ttl?)     inferred: this session has been quiet for longer than the
                 cache TTL, so the prefix has expired regardless of what
                 the stale usage fields say
  ?              usage fields unavailable

The usage numbers Claude Code passes to the statusline describe the
PREVIOUS request, so HOT/COLD(rebuilt) are authoritative but lag one
turn; COLD(ttl?) is a time inference and is marked with a "?".

The gap is measured per session via a stamp file, so several concurrent
Claude Code sessions on one machine don't reset each other's idle clock.

Configuration (environment variables):
  WARMLINE_TTL_MIN    prompt-cache TTL in minutes (default 60; set 5 if
                      your setup uses the short TTL)
  WARMLINE_STATE_DIR  stamp-file directory (default ~/.claude/warmline-state)
  WARMLINE_DEBUG      if set, keep the last raw statusline payload in
                      $WARMLINE_STATE_DIR/last-payload.json for inspection
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


def session_gap_minutes(session_id, raw):
    """Minutes since this session's previous render; None on first render."""
    gap = None
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        stamp = os.path.join(STATE_DIR, session_id + ".stamp")
        try:
            gap = (time.time() - os.path.getmtime(stamp)) / 60
        except OSError:
            pass
        with open(stamp, "w"):
            pass  # the mtime is the data
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
    return gap


def main():
    raw = sys.stdin.read()
    try:
        d = json.loads(raw)
    except ValueError:
        print("warmline: bad input")
        return

    session = str(d.get("session_id") or "default")
    session = "".join(c for c in session if c.isalnum() or c in "-_") or "default"
    gap_min = session_gap_minutes(session, raw)

    if gap_min is None:
        tp = d.get("transcript_path")
        if tp and os.path.exists(tp):
            gap_min = (time.time() - os.path.getmtime(tp)) / 60

    model = (d.get("model") or {}).get("display_name") or (d.get("model") or {}).get("id") or "?"
    ws = d.get("workspace") or {}
    cwd = os.path.basename(ws.get("current_dir") or d.get("cwd") or "") or "?"

    cw = d.get("context_window") or {}
    usage = cw.get("current_usage") or {}
    cache_read = usage.get("cache_read_input_tokens") or 0
    cache_creation = usage.get("cache_creation_input_tokens") or 0

    if gap_min is not None and gap_min > TTL_MIN:
        cache = "cache COLD(ttl?)"
    elif cache_read > 0:
        cache = "cache HOT"
    elif cache_creation > 0:
        cache = "cache COLD(rebuilt)"
    else:
        cache = "cache ?"

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

    print(" | ".join(parts))


if __name__ == "__main__":
    main()
