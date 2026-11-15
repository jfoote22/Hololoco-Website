// The scan-photo Edge Function: the automatic check on every uploaded photo.
//
// The database calls it (pg_net, from a trigger on assets) with { assetId }. It
// claims the photo, then checks every image the photo will show with Google
// Cloud Vision SafeSearch: the photo, its pin thumbnail, and each picture inside
// its framed 3D version (so a different picture can't hide in the model). It
// also checks the model is the kind the website makes: a few triangles and no
// outside links. A clean photo's files are copied to the public bucket and the
// database publishes it; a flagged one waits for a person with what was found.
//
// Anyone can call it, so it trusts nothing in the request but the id: it does
// nothing unless the database has that photo queued, and only one call can claim it.
//
// Secrets: GOOGLE_VISION_API_KEY. Without it every photo goes to a person.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "https://deno.land/x/postgresjs@v3.4.5/mod.js";
import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import { judge, readGlb, safeSearch, type ScanResult } from "./scan.ts";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 3 });

const secretKey = (() => {
  try {
    return JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}").default as string | undefined;
  } catch {
    return undefined;
  }
})() ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const storage = createClient(Deno.env.get("SUPABASE_URL")!, secretKey, { auth: { persistSession: false } }).storage;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const reply = (body: unknown, status: number) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply({ error: "post_only" }, 405);
  let assetId: unknown = null;
  try {
    ({ assetId } = await req.json());
  } catch {
    // Not JSON: answered below.
  }
  if (typeof assetId !== "string" || !UUID.test(assetId)) return reply({ error: "bad_request" }, 400);

  // Answer at once; the check carries on in the background.
  EdgeRuntime.waitUntil(run(assetId));
  return reply({ accepted: true }, 202);
});

type Claim = { assetId: string; model: string; thumbnail: string; photo: string };

async function download(path: string): Promise<Uint8Array> {
  const { data, error } = await storage.from("uploads").download(path);
  if (error || !data) throw new Error(`Couldn't read ${path.split("/").pop()}: ${error?.message ?? "missing"}`);
  return new Uint8Array(await data.arrayBuffer());
}

async function publish(claim: Claim) {
  const copies: [string, string][] = [
    [claim.model, `${claim.assetId}/model.glb`],
    [claim.thumbnail, `${claim.assetId}/thumbnail.png`],
    [claim.photo, `${claim.assetId}/photo.jpg`],
  ];
  for (const [from, to] of copies) {
    const { error } = await storage.from("uploads").copy(from, to, { destinationBucket: "drop-assets" });
    if (error && !/already exists|duplicate/i.test(error.message)) throw new Error(`Couldn't publish ${to}: ${error.message}`);
  }
}

async function run(assetId: string) {
  let claimed = false;
  try {
    const [row] = await sql`select private.claim_photo_scan(${assetId}::uuid) as claim`;
    const claim = row?.claim as Claim | null;
    if (!claim) return;
    claimed = true;

    const apiKey = Deno.env.get("GOOGLE_VISION_API_KEY");
    if (!apiKey) throw new Error("not_configured");

    const [model, thumbnail, photo] = await Promise.all([
      download(claim.model),
      download(claim.thumbnail),
      download(claim.photo),
    ]);
    const glb = readGlb(model);
    const images = [
      { name: "photo", bytes: photo },
      { name: "thumbnail", bytes: thumbnail },
      ...glb.images.map((bytes, i) => ({ name: `picture in the model ${i + 1}`, bytes })),
    ];
    const verdicts = await safeSearch(apiKey, images);
    const result: ScanResult = judge(glb, verdicts);

    const clean = result.flags.length === 0;
    if (clean) await publish(claim);
    const [finished] = await sql`
      select private.finish_photo_scan(${assetId}::uuid, ${sql.json(result)}, ${clean}) as outcome`;
    console.log(`photo ${assetId}: ${finished?.outcome}${clean ? "" : ` (${result.flags.join("; ")})`}`);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`photo ${assetId} check failed: ${message}`);
    if (!claimed) return;
    try {
      await sql`select private.fail_photo_scan(${assetId}::uuid, ${message})`;
    } catch (recordError) {
      console.error(`couldn't record the failure: ${recordError}`);
    }
  }
}
