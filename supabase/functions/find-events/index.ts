// The find-events Edge Function: Hololoco looking around town for events by itself.
//
// The database wakes it with { action: "tick" } (pg_net, from the found-tick job,
// which runs every ten minutes in the hour after each daily run). Each tick does
// whatever the tables say is waiting, inside a time budget, and stops:
//   1. A queued run becomes one search per topic that's due (every topic when staff
//      asked for the run), all sent to Claude as one Message Batch. Batches have no
//      time limit, which an Edge Function on the free plan does (150 s), and cost half.
//   2. When the batch ends, each search has either saved its events or stopped early;
//      one that stopped carries on in the next batch (up to MAX_ROUNDS requests).
//   3. Saved events are placed (place.ts) and stored as pending for staff, up to
//      MAX_EVENTS_PER_RUN for the whole run (cap.ts); past that the run stops.
//
// Anyone can call it, so it trusts nothing in the request: it only does work the
// database queued, and only the daily job or staff (run_finder) queue a run.
//
// Secrets: ANTHROPIC_API_KEY (required) and MAPBOX_TOKEN (to place events by street
// address; without it they're placed by Claude's estimate, which staff check).

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import Anthropic from "npm:@anthropic-ai/sdk@1.8.0";
import postgres from "https://deno.land/x/postgresjs@v3.4.5/mod.js";
import { budgetFor, MAX_EVENTS_PER_RUN, placeWithinBudget, type Budget } from "./cap.ts";
import { placeEvent, venueKey, type Area } from "./place.ts";
import { SAVE_TOOL, SYSTEM, TOPICS, type FoundEvent, type Topic } from "./topics.ts";

const MODEL = "claude-opus-5-5";
const MAX_ROUNDS = 4;
/** Stop starting new work after this long; the free plan ends a call at 150 s. */
const BUDGET_MS = 100_000;

// US cents per token in a batch (half the usual price) for claude-opus-5-5, and per search.
const CENTS = { input: 0.0002, output: 0.001, cacheWrite: 0.00025, cacheRead: 0.00001, search: 1 };

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 3 });

const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

// deno-lint-ignore no-explicit-any
type Json = any;

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply({ error: "post_only" }, 405);
  let action: unknown = null;
  try {
    ({ action } = await req.json());
  } catch {
    // Not JSON: answered below.
  }
  if (action !== "tick") return reply({ error: "bad_request" }, 400);

  // Answer at once; the tick carries on in the background.
  EdgeRuntime.waitUntil(tickOnce());
  return reply({ accepted: true }, 202);
});

/** One tick at a time: a lease in private.settings, taken for longer than a tick can run. */
async function tickOnce() {
  await sql`insert into private.settings (name, value) values ('found_lease', '1970-01-01') on conflict (name) do nothing`;
  const [lease] = await sql`
    update private.settings set value = now()::text
    where name = 'found_lease' and value::timestamptz < now() - interval '160 seconds'
    returning 1`;
  if (!lease) return;
  try {
    console.log(JSON.stringify(await tick()));
  } catch (error) {
    console.error(`tick failed: ${error instanceof Error ? error.stack ?? error.message : error}`);
  } finally {
    await sql`update private.settings set value = '1970-01-01' where name = 'found_lease'`;
  }
}

async function tick() {
  const started = Date.now();
  const timeLeft = () => BUDGET_MS - (Date.now() - started);
  const log: Record<string, unknown> = { mapbox: Boolean(Deno.env.get("MAPBOX_TOKEN")) };

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) {
    // Nothing can be searched: close the queued runs with a note staff see.
    const runs = await sql`update public.found_runs set status = 'done', finished_at = now() where status = 'queued' returning id`;
    for (const run of runs) {
      await sql`insert into public.found_searches (run_id, topic, status, error) values (${run.id}, 'setup', 'failed', 'not_configured')`;
    }
    return { ...log, error: "not_configured", closed: runs.length };
  }
  const client = new Anthropic({ apiKey, timeout: 60_000, maxRetries: 2 });

  log.started = await startQueuedRuns();
  if (timeLeft() > 60_000) log.read = await readBatches(client, apiKey);
  if (timeLeft() > 30_000) log.submitted = await submitWaiting(client);
  log.placed = await placeSaved(timeLeft);
  log.finished = await finishRuns();
  return log;
}

// ---------------------------------------------------------------------------
// 1. Runs become searches, and searches go out in a batch
// ---------------------------------------------------------------------------

async function startQueuedRuns() {
  const runs = await sql`
    update public.found_runs set status = 'running'
    where id in (select id from public.found_runs where status = 'queued' order by id for update skip locked)
    returning id, area_id, all_topics`;
  for (const run of runs) {
    const due: Topic[] = [];
    for (const topic of TOPICS) {
      if (run.all_topics) {
        due.push(topic);
        continue;
      }
      const [last] = await sql`
        select max(s.created_at) as at from public.found_searches s
        join public.found_runs r on r.id = s.run_id
        where s.topic = ${topic.id} and r.area_id = ${run.area_id} and s.status <> 'failed'`;
      // Half a day's slack, so a run a little earlier than yesterday's still counts.
      if (!last?.at || Date.now() - new Date(last.at).getTime() > (topic.every - 0.5) * 86_400_000) due.push(topic);
    }
    for (const topic of due) {
      await sql`insert into public.found_searches (run_id, topic) values (${run.id}, ${topic.id})`;
    }
  }
  return runs.length;
}

async function submitWaiting(client: Anthropic) {
  return await sql.begin(async (tx) => {
    const waiting = await tx`
      select s.id, s.topic, s.round, s.messages, s.status, r.area_id
      from public.found_searches s join public.found_runs r on r.id = s.run_id
      where s.status in ('queued', 'continue') and s.round < ${MAX_ROUNDS}
        -- A run that has already added its cap gets no more searches sent (see cap.ts);
        -- placeSaved marks them done, but this tick's batch would go out before that.
        and coalesce((select sum(s2.added) from public.found_searches s2 where s2.run_id = s.run_id), 0)
            < ${MAX_EVENTS_PER_RUN}
      order by s.id
      for update of s skip locked
      limit 40`;
    if (waiting.length === 0) return 0;

    const requests: Json[] = [];
    const conversations = new Map<number, Json[]>();
    for (const search of waiting) {
      const topic = TOPICS.find((t) => t.id === search.topic);
      const area = await areaOf(tx, search.area_id);
      if (!topic || !area) {
        await tx`update public.found_searches set status = 'failed', error = 'unknown_topic', updated_at = now() where id = ${search.id}`;
        continue;
      }
      const messages: Json[] = search.status === "queued" ? [{ role: "user", content: await firstMessage(tx, area, topic) }] : search.messages;
      conversations.set(search.id, messages);
      requests.push({ custom_id: `s${search.id}r${search.round + 1}`, params: requestFor(area, messages) });
    }
    if (requests.length === 0) return 0;

    let batchId: string;
    try {
      batchId = (await client.messages.batches.create({ requests })).id;
    } catch (error) {
      // A bad key or a malformed request won't fix itself: fail these where staff can see why.
      const why = error instanceof Anthropic.APIError ? `batch_refused: ${error.status} ${error.message}` : `batch_failed: ${error}`;
      for (const id of conversations.keys()) {
        await tx`update public.found_searches set status = 'failed', error = ${why.slice(0, 300)}, updated_at = now() where id = ${id}`;
      }
      return 0;
    }
    for (const [id, messages] of conversations) {
      await tx`
        update public.found_searches
        set status = 'submitted', batch_id = ${batchId}, round = round + 1, messages = ${sql.json(messages)}, updated_at = now()
        where id = ${id}`;
    }
    return requests.length;
  });
}

async function areaOf(tx: postgres.Sql, id: string): Promise<Area | null> {
  const [area] = await tx`select id, name, lat, lng, radius_km, time_zone from public.found_areas where id = ${id}`;
  return (area as Area) ?? null;
}

function requestFor(area: Area, messages: Json[]) {
  const [city, region] = area.name.split(",").map((s) => s.trim());
  return {
    model: MODEL,
    max_tokens: 32000,
    output_config: { effort: "medium" },
    system: [{ type: "text", text: SYSTEM, cache_control: { type: "ephemeral" } }],
    tools: [
      {
        type: "web_search_20260209",
        name: "web_search",
        max_uses: 15,
        user_location: { type: "approximate", city, region, country: "US", timezone: area.time_zone },
      },
      { type: "web_fetch_20260209", name: "web_fetch", max_uses: 15, max_content_tokens: 40000 },
      SAVE_TOOL,
    ],
    messages,
  };
}

const longDate = (date: Date, timeZone: string) =>
  date.toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric", year: "numeric", timeZone });

async function firstMessage(tx: postgres.Sql, area: Area, topic: Topic) {
  const now = new Date();
  const until = new Date(now.getTime() + topic.days * 86_400_000);
  // What's already known in this topic's categories, so the search goes after new things.
  const known = await tx`
    select title, to_char(starts_at at time zone ${area.time_zone}, 'YYYY-MM-DD') as day
    from public.found_events
    where area_id = ${area.id} and category = any (${topic.categories}) and ends_at > now()
    order by starts_at
    limit 150`;
  const knownList = known.length
    ? `\n\nAlready found, so skip these (unless you find they've changed):\n${known.map((k) => `- ${k.title} (${k.day})`).join("\n")}`
    : "";
  return (
    `Area: ${area.name}, and the towns around it, within about ${Math.round(area.radius_km)} km of downtown.\n` +
    `Today: ${longDate(now, area.time_zone)}. Times are local (${area.time_zone}).\n` +
    `Topic: ${topic.label}. ${topic.brief}\n` +
    `Window: things that start from today through ${longDate(until, area.time_zone)}; for giveaways and deals, ones running on or after today.` +
    knownList
  );
}

// ---------------------------------------------------------------------------
// 2. Reading a finished batch
// ---------------------------------------------------------------------------

// The results file holds every page Claude read, so it's large, and a call gets
// about 2 s of CPU. So the file is streamed line by line, lines for searches
// already read are skipped without parsing, and a tick reads a few results at most.
const RESULTS_PER_TICK = 3;

async function readBatches(client: Anthropic, apiKey: string) {
  const pending = await sql`
    select id, round, messages, batch_id from public.found_searches
    where status = 'submitted' and batch_id is not null`;
  const byBatch = new Map<string, Map<string, { id: number; round: number; messages: Json[] }>>();
  for (const s of pending) {
    if (!byBatch.has(s.batch_id)) byBatch.set(s.batch_id, new Map());
    byBatch.get(s.batch_id)!.set(`s${s.id}r${s.round}`, { id: s.id, round: s.round, messages: s.messages });
  }

  let read = 0;
  for (const [batchId, waiting] of byBatch) {
    const batch = await client.messages.batches.retrieve(batchId);
    if (batch.processing_status !== "ended" || !batch.results_url) continue;
    const response = await fetch(batch.results_url, {
      headers: { "x-api-key": apiKey, "anthropic-version": "2023-06-01" },
    });
    if (!response.ok || !response.body) throw new Error(`batch results: ${response.status}`);
    for await (const line of lines(response.body)) {
      const customId = /"custom_id"\s*:\s*"([^"]+)"/.exec(line.slice(0, 300))?.[1];
      const search = customId ? waiting.get(customId) : undefined;
      if (!search) continue;
      await readResult(search, JSON.parse(line));
      waiting.delete(customId!);
      if (++read >= RESULTS_PER_TICK || waiting.size === 0) break;
    }
    if (read >= RESULTS_PER_TICK) break;
  }
  return read;
}

/** The lines of a JSONL stream, without rescanning what's already been read. */
async function* lines(body: ReadableStream<Uint8Array>) {
  const reader = body.pipeThrough(new TextDecoderStream()).getReader();
  let parts: string[] = [];
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      let start = 0;
      let newline: number;
      while ((newline = value.indexOf("\n", start)) >= 0) {
        parts.push(value.slice(start, newline));
        const line = parts.join("");
        parts = [];
        if (line.trim()) yield line;
        start = newline + 1;
      }
      if (start < value.length) parts.push(value.slice(start));
    }
    const rest = parts.join("");
    if (rest.trim()) yield rest;
  } finally {
    reader.cancel().catch(() => {});
  }
}

async function readResult(search: { id: number; round: number; messages: Json[] }, result: Json) {
  const carryOn = async (messages: Json[], error: string) => {
    if (search.round >= MAX_ROUNDS) {
      await sql`update public.found_searches set status = 'failed', error = ${error}, messages = null, updated_at = now() where id = ${search.id}`;
    } else {
      await sql`update public.found_searches set status = 'continue', error = ${error}, messages = ${sql.json(messages)}, updated_at = now() where id = ${search.id}`;
    }
  };

  if (result.result.type !== "succeeded") {
    const why = result.result.type === "errored" ? `errored: ${result.result.error?.error?.message ?? "unknown"}` : result.result.type;
    // A request the API turned down won't go better the second time.
    if (result.result.error?.error?.type === "invalid_request_error") {
      await sql`update public.found_searches set status = 'failed', error = ${why}, messages = null, updated_at = now() where id = ${search.id}`;
    } else {
      await carryOn(search.messages, why);
    }
    return;
  }

  const message = result.result.message;
  const usage = message.usage ?? {};
  const cents =
    (usage.input_tokens ?? 0) * CENTS.input +
    (usage.output_tokens ?? 0) * CENTS.output +
    (usage.cache_creation_input_tokens ?? 0) * CENTS.cacheWrite +
    (usage.cache_read_input_tokens ?? 0) * CENTS.cacheRead +
    (usage.server_tool_use?.web_search_requests ?? 0) * CENTS.search;
  await sql`
    update public.found_searches set
      cost_cents = cost_cents + ${Math.round(cents * 100) / 100},
      usage = jsonb_build_object(
        'input', coalesce((usage ->> 'input')::bigint, 0) + ${usage.input_tokens ?? 0},
        'output', coalesce((usage ->> 'output')::bigint, 0) + ${usage.output_tokens ?? 0},
        'cacheWrite', coalesce((usage ->> 'cacheWrite')::bigint, 0) + ${usage.cache_creation_input_tokens ?? 0},
        'cacheRead', coalesce((usage ->> 'cacheRead')::bigint, 0) + ${usage.cache_read_input_tokens ?? 0},
        'searches', coalesce((usage ->> 'searches')::bigint, 0) + ${usage.server_tool_use?.web_search_requests ?? 0},
        'fetches', coalesce((usage ->> 'fetches')::bigint, 0) + ${usage.server_tool_use?.web_fetch_requests ?? 0})
    where id = ${search.id}`;

  const save = (message.content as Json[]).find((b) => b.type === "tool_use" && b.name === "save_events");
  if (save && Array.isArray(save.input?.events)) {
    await sql`
      update public.found_searches set status = 'placing', found = ${sql.json(save.input.events)}, placed = 0,
        messages = null, error = null, updated_at = now()
      where id = ${search.id}`;
    return;
  }

  switch (message.stop_reason) {
    case "pause_turn":
      // A long search paused on the server: send it back as it is to carry on.
      await carryOn([...search.messages, { role: "assistant", content: message.content }], "paused");
      return;
    case "refusal":
      await sql`update public.found_searches set status = 'failed', error = 'declined', messages = null, updated_at = now() where id = ${search.id}`;
      return;
    default: {
      // It finished without saving, or ran out of room: ask for the save.
      const content = (message.content as Json[]).filter((b) => b.type !== "tool_use");
      const ask = message.stop_reason === "max_tokens"
        ? "Your answer was cut off. Call save_events now with the best 40 events you found."
        : "Call save_events now with every event you found, or with an empty list if you found none.";
      const messages = content.length
        ? [...search.messages, { role: "assistant", content }, { role: "user", content: ask }]
        : search.messages;
      await carryOn(messages, `no_save: ${message.stop_reason}`);
    }
  }
}

// ---------------------------------------------------------------------------
// 3. Placing what was saved
// ---------------------------------------------------------------------------

async function placeSaved(timeLeft: () => number) {
  let placed = 0;
  let added = 0;
  let duplicates = 0;
  let capped = false;
  const searches = await sql`
    select s.id, s.found, s.placed, r.id as run_id, r.area_id
    from public.found_searches s join public.found_runs r on r.id = s.run_id
    where s.status = 'placing' order by s.id`;
  // One budget per run, shared by its searches and carried across this tick's searches.
  const budgets = new Map<number, Budget>();
  for (const search of searches) {
    const area = await areaOf(sql, search.area_id);
    const events = (search.found ?? []) as FoundEvent[];
    let budget = budgets.get(search.run_id);
    if (!budget) {
      budget = budgetFor(await addedInRun(search.run_id));
      budgets.set(search.run_id, budget);
    }

    const result = await placeWithinBudget(
      events,
      search.placed as number,
      budget,
      () => timeLeft() > 8_000,
      async (event, index) => {
        try {
          const spot = area && event?.title ? await placeEvent(sql, area, event) : null;
          if (!spot) return "skipped: no location";
          const [row] = await sql`
            select private.found_save_event(${search.id}, ${area!.id},
              ${sql.json({ ...event, ...spot, venue_key: spot.venue_key ?? venueKey(area!.id, event) })}) as outcome`;
          return row.outcome as string;
        } catch (error) {
          console.error(`placing ${search.id}#${index}: ${error instanceof Error ? error.message : error}`);
          return "skipped: unreadable";
        }
      },
    );
    const { index, counts, capped: hitCap } = result;

    // Capped: the rest of this search's events are dropped and the search is finished,
    // because the run has no room for them however long it keeps trying.
    const done = hitCap || index >= events.length;
    await sql`
      update public.found_searches set
        placed = ${index}, added = added + ${counts.added}, duplicates = duplicates + ${counts.duplicates},
        skipped = skipped + ${counts.skipped},
        status = ${done ? "done" : "placing"}, found = case when ${done} then null else found end,
        error = case when ${hitCap} then 'capped' else error end, updated_at = now()
      where id = ${search.id}`;
    placed += index - (search.placed as number);
    added += counts.added;
    duplicates += counts.duplicates;
    if (hitCap) {
      capped = true;
      await stopAtCap(search.run_id);
    }
    if (!done) break;
  }
  return { placed, events_added: added, duplicates, capped };
}

/** How many events a run has inserted so far, from its searches' own counters. */
async function addedInRun(runId: number) {
  const [row] = await sql`
    select coalesce(sum(s.added), 0)::int as added from public.found_searches s where s.run_id = ${runId}`;
  return row.added as number;
}

/**
 * The run is full: finish its other searches without sending them. They're done, not
 * failed — nothing went wrong with them, there's just nowhere left to put what they'd
 * find, and a Claude call for that is money burnt. One already in a batch is left
 * where it is; the batch's own results are never read.
 */
async function stopAtCap(runId: number) {
  const stopped = await sql`
    update public.found_searches set
      status = 'done', error = coalesce(error, 'capped'), found = null, messages = null, updated_at = now()
    where run_id = ${runId} and status not in ('done', 'failed')
    returning id`;
  if (stopped.length > 0) console.log(`run ${runId} hit MAX_EVENTS_PER_RUN: ${stopped.length} searches stopped`);
  return stopped.length;
}

async function finishRuns() {
  const runs = await sql`
    update public.found_runs r set status = 'done', finished_at = now()
    where r.status = 'running'
      and not exists (select 1 from public.found_searches s where s.run_id = r.id and s.status not in ('done', 'failed'))
    returning id`;
  return runs.length;
}
