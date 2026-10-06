// warmline's cache gauge for the surfaces that render no statusLine.
//
// Claude Code Desktop's Code tab draws no `statusLine`, so the gauge that
// `warmline-statusline.py` prints never reaches it. This mod draws the band
// above the prompt instead, from what a plugin can see: the four token counts
// of every main-thread response. Each one is graded as `warmline audit` grades
// it (verdict_of in warmline-audit), and the session's tally is kept.
//
// What it deliberately does not say is whether the prefix is warm *now*.
// Claude Code's `prompt_cache` object (warm, TTL, expiry) reaches the
// statusline alone; the plugin API exposes none of it. So the band reports
// the last response's grade and how long ago it landed, both facts, and
// leaves the TTL arithmetic to the reader.
//
// On the terminal, where warmline's statusLine is wired, the band yields: the
// statusline is the better instrument there, and one gauge is enough.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, TurnUsage } from 'claude-code'
import type { Counts, Verdict } from '../types'

const gauge = atom({ plugin: 'warmline', key: 'gauge' } as const, null)
const isHidden = atom({ plugin: 'warmline', key: 'isHidden' } as const, false)
const tick = atom({ plugin: 'warmline', key: 'tick' } as const, 0)

const COLOR: Record<Verdict, string | undefined> = {
  HOT: 'green',
  PARTIAL: 'yellow',
  COLD: 'red',
  '?': undefined,
}

/**
 * verdict_of() from warmline-audit, less its COLD(ttl)/COLD(rebuilt) split:
 * that needs the gap against the TTL, and a mod sees no TTL.
 */
function verdictOf(cacheRead: number, cacheWrite: number): Verdict {
  if (cacheRead > 0) return cacheWrite > cacheRead ? 'PARTIAL' : 'HOT'
  if (cacheWrite > 0) return 'COLD'
  return '?'
}

/** fmt_tokens() from statusline.py: 127000 -> 127k, 1240000 -> 1.2M. */
function fmtTokens(n: number): string {
  if (n >= 999500) return `${(n / 1e6).toFixed(1).replace(/\.0$/, '')}M`
  return `${Math.round(n / 1000)}k`
}

function fmtAgo(ms: number): string {
  const min = Math.floor(ms / 60_000)
  if (min < 1) return 'just now'
  if (min < 60) return `${min} min ago`
  const h = Math.floor(min / 60)
  const m = min % 60
  return m === 0 ? `${h} h ago` : `${h} h ${m} min ago`
}

function stake(verdict: Verdict, cacheRead: number, cacheWrite: number): string {
  switch (verdict) {
    case 'HOT':
      return `read ${fmtTokens(cacheRead)}`
    case 'PARTIAL':
      return `wrote ${fmtTokens(cacheWrite)}, read ${fmtTokens(cacheRead)}`
    case 'COLD':
      return `wrote ${fmtTokens(cacheWrite)}`
    default:
      return 'no cache tokens'
  }
}

/** The terminal renders `statusLine`; where warmline's is wired, that is the gauge to read. */
async function hasWarmlineStatusLine($: EngineInterface): Promise<boolean> {
  try {
    const settings = await $.settings.read()
    const statusLine = settings.statusLine
    const command =
      statusLine && typeof statusLine === 'object' ? (statusLine as { command?: unknown }).command : undefined
    return typeof command === 'string' && /warmline/i.test(command)
  } catch {
    return false
  }
}

async function record($: EngineInterface, usage: TurnUsage | null): Promise<void> {
  if (!usage) return
  const cacheRead = usage.cache_read_input_tokens
  const cacheWrite = usage.cache_creation_input_tokens
  // Nothing on the input side is a synthetic entry with no request behind it; the auditor skips those too.
  if (!cacheRead && !cacheWrite && !usage.input_tokens) return
  const verdict = verdictOf(cacheRead, cacheWrite)
  const at = await $.clock.now()
  await update($, gauge, (g) => {
    const counts: Counts = { ...(g?.counts ?? { HOT: 0, PARTIAL: 0, COLD: 0 }) }
    if (verdict !== '?') counts[verdict] += 1
    return { last: { verdict, cacheRead, cacheWrite, at }, counts }
  })
}

export const register: Register = (on) => {
  on('session.start', ($, e, next) => {
    // Once a minute, so "n min ago" stays current while the session idles.
    $.clock.every(60_000, () => update($, tick, (n) => n + 1))
    return next(e)
  })

  on('turn.step', async function* ($, e, next) {
    const result = yield* next(e)
    if (e.agentId === undefined) {
      try {
        await record($, result.usage)
      } catch {
        // A failed record must never touch the response.
      }
    }
    return result
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey || (await read($, isHidden))) return next(e)
    if (e.surface === 'terminal' && (await hasWarmlineStatusLine($))) return next(e)

    const g = await read($, gauge)
    await read($, tick) // subscribes the band to the minute tick
    const { Box, Button, Text } = $.ui.resolve(e)

    if (g === null) {
      return (
        <Box gap={1}>
          <Text dimColor>warmline</Text>
          <Text dimColor>
            cache ?
          </Text>
          <Text dimColor>
            no response yet
          </Text>
          <Button key="hide" label="Hide" onPress={() => update($, isHidden, () => true)} />
        </Box>
      )
    }

    const { last, counts } = g
    const ago = fmtAgo((await $.clock.now()) - last.at)
    return (
      <Box gap={1}>
        <Text dimColor>warmline</Text>
        <Text>last turn</Text>
        <Text color={COLOR[last.verdict]} bold>
          {last.verdict}
        </Text>
        <Text>{`(${stake(last.verdict, last.cacheRead, last.cacheWrite)})`}</Text>
        <Text dimColor>
          {ago}
        </Text>
        <Text dimColor>
          {`· session ${counts.HOT} hot ${counts.PARTIAL} partial ${counts.COLD} cold`}
        </Text>
        <Button key="hide" label="Hide" onPress={() => update($, isHidden, () => true)} />
      </Box>
    )
  })
}
