// The hard cap on one run: at most MAX_EVENTS_PER_RUN events reach found_events from
// a single found_runs row, however many topics it searched.
//
// Why: one real search added 246 events (70 from comedy alone), which is more than
// staff can review and more than the small compute wants to write. The cap is counted
// per run rather than per search so no mix of topics can add up past it, and it's
// counted at the insert point, so events the database skips or folds into one it
// already has (private.found_save_event returning 'duplicate' or 'skipped: …') cost
// nothing. When the budget runs out the run's remaining searches are marked done, not
// failed: there's nothing wrong with them, they just aren't worth a Claude call.
//
// placeWithinBudget holds the whole rule and touches no database, so cap.test.ts can
// drive it with made-up outcomes: `node cap.test.ts` (or `deno run cap.test.ts`).

/** At most this many events are inserted per run, across every topic and search in it. */
export const MAX_EVENTS_PER_RUN = 20;

/** What a run has left to spend. One object is shared by every search in the run. */
export type Budget = { left: number };

/** A run's budget, after what its searches have already inserted. */
export function budgetFor(addedInRun: number): Budget {
  return { left: Math.max(0, MAX_EVENTS_PER_RUN - Math.max(0, addedInRun)) };
}

export type Counts = { added: number; duplicates: number; skipped: number };

export type Placing = {
  /** How far through the list placing got; events before this index are dealt with. */
  index: number;
  counts: Counts;
  /** Events were left over and the run's budget was gone: the run stops here. */
  capped: boolean;
};

/**
 * Places a search's events, from `from`, while the run has budget and the tick has time.
 * `save` stores one event and returns what private.found_save_event said about it
 * ('added', 'duplicate' or 'skipped: why'); it isn't called once the budget is gone.
 */
export async function placeWithinBudget<T>(
  events: T[],
  from: number,
  budget: Budget,
  hasTime: () => boolean,
  save: (event: T, index: number) => Promise<string>,
): Promise<Placing> {
  const counts: Counts = { added: 0, duplicates: 0, skipped: 0 };
  let index = Math.max(0, from);
  while (index < events.length) {
    // Out of room, with events still in hand: the cap, not the work, ends this run.
    if (budget.left <= 0) return { index, counts, capped: true };
    if (!hasTime()) break;
    const outcome = await save(events[index], index);
    index++;
    if (outcome === "added") {
      counts.added++;
      budget.left--;
    } else if (outcome === "duplicate") {
      counts.duplicates++;
    } else {
      counts.skipped++;
    }
  }
  return { index, counts, capped: false };
}
