// The values the warmline mod keeps in `$.state`, declared so that
// `claude plugin validate` can hold the module to them.

/** The grade of one API response, as `warmline audit` spells it. */
export type Verdict = 'HOT' | 'PARTIAL' | 'COLD' | '?'

/** How many of this session's main-thread responses took each grade. */
export type Counts = { HOT: number; PARTIAL: number; COLD: number }

/** The last main-thread response: its grade, its cache traffic, when it landed. */
export type LastTurn = { verdict: Verdict; cacheRead: number; cacheWrite: number; at: number }

export type Gauge = { last: LastTurn; counts: Counts }

declare module 'claude-code' {
  interface PluginState {
    warmline: { gauge: Gauge | null; isHidden: boolean; tick: number }
  }
}
