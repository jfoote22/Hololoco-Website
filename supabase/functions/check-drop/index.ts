// The check-drop Edge Function: the automatic check on every drop someone adds
// or changes.
//
// The database calls it (pg_net, from a trigger on drops) with { dropId }, and a
// job every minute calls it again for anything stuck. It claims the drop, asks
// Claude whether it can go live (check.ts), and records the answer, all through
// the private.* functions in the offers_and_checks migration, over the direct
// database connection every Edge Function has.
//
// Anyone can call it, so it trusts nothing in the request but the id: it does
// nothing unless the database has that drop queued, and only one call can claim it.
//
// Secrets: ANTHROPIC_API_KEY (without it every drop goes to a person) and
// MAPBOX_TOKEN (optional: a public token, for what's around the spot).

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "https://deno.land/x/postgresjs@v3.4.5/mod.js";
import { checkDrop, NotConfigured, type CheckContext } from "./check.ts";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 3 });

const DROP_ID = /^[a-z0-9]{8}$/;

const reply = (body: unknown, status: number) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply({ error: "post_only" }, 405);
  let dropId: unknown = null;
  try {
    ({ dropId } = await req.json());
  } catch {
    // Not JSON: answered below.
  }
  if (typeof dropId !== "string" || !DROP_ID.test(dropId)) return reply({ error: "bad_request" }, 400);

  // Answer at once; the check carries on in the background.
  EdgeRuntime.waitUntil(run(dropId));
  return reply({ accepted: true }, 202);
});

async function run(dropId: string) {
  let runId: number | null = null;
  try {
    const [claimed] = await sql`select private.claim_check(${dropId}) as ctx`;
    const ctx = claimed?.ctx as CheckContext | null;
    if (!ctx) return;
    runId = Number(ctx.runId);

    const result = await checkDrop(ctx);
    const [finished] = await sql`
      select private.finish_check(${runId}::bigint, ${sql.json(result)}) as applied`;
    console.log(`check ${runId} for ${dropId}: ${result.decision}, applied ${finished?.applied}`);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`check ${runId ?? "-"} for ${dropId} failed: ${message}`);
    if (runId === null) return;
    try {
      await sql`select private.fail_check(${runId}::bigint, ${message}, ${error instanceof NotConfigured})`;
    } catch (recordError) {
      // The retry job picks it up after five minutes.
      console.error(`couldn't record the failure: ${recordError}`);
    }
  }
}
