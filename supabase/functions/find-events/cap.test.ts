// Checks the per-run cap (cap.ts) without a database or a Claude call: `save` is a
// list of made-up outcomes. The repo has no JavaScript test runner, so this file is
// its own: run it with `node cap.test.ts` or `deno run cap.test.ts`, and it prints a
// line per test and ends with a non-zero status if any of them failed.

import { budgetFor, MAX_EVENTS_PER_RUN, placeWithinBudget, type Budget } from "./cap.ts";

let failures = 0;

function check(name: string, got: unknown, want: unknown) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) failures++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : `\n     got  ${JSON.stringify(got)}\n     want ${JSON.stringify(want)}`}`);
}

/** A search whose events save as the given outcomes, remembering what was asked for. */
function search(outcomes: string[]) {
  const asked: number[] = [];
  return {
    events: outcomes.map((_, i) => ({ title: `event ${i}` })),
    asked,
    save: (_event: { title: string }, index: number) => {
      asked.push(index);
      return Promise.resolve(outcomes[index]);
    },
  };
}

const always = () => true;
const repeat = (outcome: string, n: number) => Array.from({ length: n }, () => outcome);

async function run(): Promise<number> {
  check("the cap is twenty", MAX_EVENTS_PER_RUN, 20);
  check("a fresh run has the whole cap", budgetFor(0), { left: 20 });
  check("what a run already added comes off its budget", budgetFor(15), { left: 5 });
  check("a run that somehow went over gets no more", budgetFor(25), { left: 0 });

  // A search inside the cap places everything it found.
  {
    const s = search(repeat("added", 8));
    const result = await placeWithinBudget(s.events, 0, budgetFor(0), always, s.save);
    check("a small search places all of it", result, { index: 8, counts: { added: 8, duplicates: 0, skipped: 0 }, capped: false });
  }

  // A search over the cap stops at twenty, and never offers the rest to the database.
  {
    const s = search(repeat("added", 70));
    const budget = budgetFor(0);
    const result = await placeWithinBudget(s.events, 0, budget, always, s.save);
    check("a big search stops at the cap", result, { index: 20, counts: { added: 20, duplicates: 0, skipped: 0 }, capped: true });
    check("nothing past the cap is even tried", s.asked.length, 20);
    check("the budget is spent", budget.left, 0);
  }

  // Duplicates and skips are free: they don't use up anyone's budget.
  {
    const s = search([...repeat("duplicate", 30), ...repeat("skipped: no location", 10), ...repeat("added", 20)]);
    const result = await placeWithinBudget(s.events, 0, budgetFor(0), always, s.save);
    check("duplicates and skips don't count against the cap", result, {
      index: 60,
      counts: { added: 20, duplicates: 30, skipped: 10 },
      capped: false,
    });
  }

  // Every search in a run shares one budget, so topics can't add up past the cap.
  {
    const budget: Budget = budgetFor(0);
    const first = search(repeat("added", 12));
    const second = search(repeat("added", 12));
    const third = search(repeat("added", 12));
    const a = await placeWithinBudget(first.events, 0, budget, always, first.save);
    const b = await placeWithinBudget(second.events, 0, budget, always, second.save);
    const c = await placeWithinBudget(third.events, 0, budget, always, third.save);
    check("the first topic fits", [a.counts.added, a.capped], [12, false]);
    check("the second topic gets what's left", [b.counts.added, b.capped], [8, true]);
    check("the third topic gets nothing", [c.counts.added, c.index, c.capped], [0, 0, true]);
    check("a capped topic asks the database for nothing", third.asked, []);
    check("the run added exactly the cap", a.counts.added + b.counts.added + c.counts.added, MAX_EVENTS_PER_RUN);
  }

  // A run already at the cap places nothing at all.
  {
    const s = search(repeat("added", 5));
    const result = await placeWithinBudget(s.events, 0, budgetFor(MAX_EVENTS_PER_RUN), always, s.save);
    check("a run at the cap places nothing", result, { index: 0, counts: { added: 0, duplicates: 0, skipped: 0 }, capped: true });
  }

  // A search with nothing left to place is finished, not capped.
  {
    const s = search(repeat("added", 3));
    const result = await placeWithinBudget(s.events, 3, budgetFor(MAX_EVENTS_PER_RUN), always, s.save);
    check("an empty tail is done, not capped", result, { index: 3, counts: { added: 0, duplicates: 0, skipped: 0 }, capped: false });
  }

  // Running out of time in a tick is not the cap: placing carries on where it stopped.
  {
    const s = search(repeat("added", 10));
    const budget = budgetFor(0);
    let ticks = 4;
    const first = await placeWithinBudget(s.events, 0, budget, () => ticks-- > 0, s.save);
    check("the tick's time budget stops placing without capping", first, {
      index: 4,
      counts: { added: 4, duplicates: 0, skipped: 0 },
      capped: false,
    });
    const rest = await placeWithinBudget(s.events, first.index, budget, always, s.save);
    check("the next tick carries on from there", rest, { index: 10, counts: { added: 6, duplicates: 0, skipped: 0 }, capped: false });
    check("every event was placed once", s.asked, [...Array(10).keys()]);
  }

  console.log(failures === 0 ? "\nall tests passed" : `\n${failures} test${failures === 1 ? "" : "s"} failed`);
  return failures;
}

const failed = await run();
if (failed > 0) {
  // Deno and Node both read a non-zero exit status as a failed run.
  const deno = (globalThis as { Deno?: { exit(code: number): never } }).Deno;
  if (deno) deno.exit(1);
  (globalThis as { process?: { exitCode: number } }).process!.exitCode = 1;
}
