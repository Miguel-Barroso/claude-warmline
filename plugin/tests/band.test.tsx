// The band is exercised through the engine: a response is streamed beneath the
// plugin, the band is drawn on a surface, and what it says is read back.
import { expect, mock, test } from 'claude-code/testing'
import type { On, RenderSurface, TurnStepResult, TurnUsage } from 'claude-code'
import type { Engine } from 'claude-code/testing'

const BAND = {
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 10,
    bodyColumns: 120,
    scroll: { offset: 0, bodyRows: 10 },
    view: {},
  },
} as const

const STEP = { turnId: 't1', index: 0, model: 'claude-test', messageCount: 3 }
const NOW = Date.UTC(2026, 9, 6, 11, 2)

function usageOf(cacheRead: number, cacheWrite: number, input = 0): TurnUsage {
  return {
    input_tokens: input,
    output_tokens: 10,
    cache_read_input_tokens: cacheRead,
    cache_creation_input_tokens: cacheWrite,
    model: 'claude-test',
  }
}

/**
 * The engine beneath the plugin: a session that starts, its own empty band, and
 * a model whose next response costs what the test says. Returns that usage's setter.
 */
function engineBeneath(on: On) {
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Box } = $.ui.resolve(e)
    return <Box />
  })
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  let usage: TurnUsage | null = null
  on('turn.step', async function* (_$, e) {
    yield { kind: 'stop', index: 0, stopReason: 'end_turn', usage }
    const result: TurnStepResult = { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'end_turn', usage }
    return result
  })
  return (next: TurnUsage | null) => {
    usage = next
  }
}

/** One model request of the main thread, or of a subagent when `agentId` is given. */
async function respond($: Engine, agentId?: string) {
  const stream = $.turn.step(agentId === undefined ? STEP : { ...STEP, agentId })
  for await (const _chunk of stream) {
    // drained: the plugin's hook records the stop chunk's usage on the way
  }
}

async function gradesAsTheAuditorDoes(surface: RenderSurface, $: Engine, on: On) {
  const clock = mock.clock(on, { now: NOW })
  const costs = engineBeneath(on)
  await $.session.start({ cwd: '/tmp/warmline-test', surface, isInteractive: true })
  const ui = await $.ui.mount({ plugin: 'warmline', surface, ...BAND })
  const says = async (text: RegExp) => (await ui.find({ type: 'Text', text })) !== undefined

  // Before the first response the band says it cannot see yet.
  expect(await says(/^cache \?$/)).toBe(true)
  expect(await says(/^no response yet$/)).toBe(true)

  costs(usageOf(127_000, 0)) // read it all back: HOT
  await respond($)
  expect(await says(/^HOT$/)).toBe(true)
  expect(await says(/^\(read 127k\)$/)).toBe(true)
  expect(await says(/^just now$/)).toBe(true)
  expect(await says(/^· session 1 hot 0 partial 0 cold$/)).toBe(true)

  // The minute tick keeps "ago" current while nothing else redraws the band.
  await clock.advance(47 * 60_000)
  expect(await says(/^47 min ago$/)).toBe(true)

  costs(usageOf(40_000, 87_000)) // wrote more than it read: PARTIAL
  await respond($)
  expect(await says(/^PARTIAL$/)).toBe(true)
  expect(await says(/^\(wrote 87k, read 40k\)$/)).toBe(true)
  expect(await says(/^· session 1 hot 1 partial 0 cold$/)).toBe(true)

  costs(usageOf(0, 1_240_000)) // nothing read back: COLD
  await respond($)
  expect(await says(/^COLD$/)).toBe(true)
  expect(await says(/^\(wrote 1\.2M\)$/)).toBe(true)
  expect(await says(/^just now$/)).toBe(true)
  expect(await says(/^· session 1 hot 1 partial 1 cold$/)).toBe(true)

  await clock.advance(65 * 60_000)
  expect(await says(/^1 h 5 min ago$/)).toBe(true)

  // What the auditor skips, the band skips: a synthetic entry, a response without usage, a subagent's step.
  costs(usageOf(0, 0, 0))
  await respond($)
  costs(null)
  await respond($)
  costs(usageOf(500_000, 0))
  await respond($, 'subagent-1')
  expect(await says(/^COLD$/)).toBe(true)
  expect(await says(/^· session 1 hot 1 partial 1 cold$/)).toBe(true)

  // Input tokens but no cache traffic: shown as unknown, not counted.
  costs(usageOf(0, 0, 900))
  await respond($)
  expect(await says(/^\?$/)).toBe(true)
  expect(await says(/^\(no cache tokens\)$/)).toBe(true)
  expect(await says(/^· session 1 hot 1 partial 1 cold$/)).toBe(true)

  await ui.unmount()
}

test('desktop: grades each main-thread response as warmline audit would', ($, on) => gradesAsTheAuditorDoes('desktop', $, on))
test('terminal: the same band where no warmline statusLine is wired', ($, on) => gradesAsTheAuditorDoes('terminal', $, on))

test('yields to a survey, and to Hide', async ($, on) => {
  mock.clock(on, { now: NOW })
  engineBeneath(on)

  const survey = await $.ui.mount({ plugin: 'warmline', surface: 'desktop', ...BAND, props: { ...BAND.props, hasSurvey: true } })
  expect(await survey.find({ type: 'Text', text: /warmline/ })).toBeUndefined()
  await survey.unmount()

  const ui = await $.ui.mount({ plugin: 'warmline', surface: 'desktop', ...BAND })
  expect(await ui.find({ type: 'Text', text: /warmline/ })).toBeDefined()
  await ui.press({ key: 'hide' })
  expect(await ui.find({ type: 'Text', text: /warmline/ })).toBeUndefined()
  await ui.unmount()
})
