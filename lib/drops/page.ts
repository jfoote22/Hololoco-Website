import "server-only";
import { cacheLife, cacheTag } from "next/cache";
import { anonClient } from "@/lib/supabase/anon";
import { dropFromJson, type DropJson } from "./json";
import { sampleDrops, showSamples } from "./sample";
import type { PublicDrop } from "./types";

/** The tag on a drop's cached page data. Saving, pausing or deleting the drop refreshes it. */
export const dropTag = (id: string) => `drop:${id}`;

/**
 * One drop for its own page and link preview. Link-only drops are included, since
 * having the link is the point; drops in review or paused are not.
 */
export async function getDrop(id: string): Promise<PublicDrop | null> {
  "use cache";
  cacheTag(dropTag(id));
  cacheLife("minutes");

  const sample = showSamples ? sampleDrops.find((d) => d.id === id && d.status === "live") : undefined;
  if (sample) return sample;
  if (!/^[a-z0-9]{4,16}$/.test(id)) return null;

  const client = anonClient();
  if (!client) return null;
  const { data, error } = await client.rpc("public_drop", { drop_id: id });
  // Thrown, not cached: a database hiccup shouldn't read as "this drop doesn't exist".
  if (error) throw new Error(`Couldn't load drop ${id}: ${error.message}`);
  return data ? dropFromJson(data as DropJson) : null;
}

/** Drop pages prerendered at build time. Cache Components needs at least one. */
export function prerenderedDropIds(): string[] {
  return sampleDrops.map((d) => d.id);
}
