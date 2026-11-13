// Where the map's drops come from: the database, plus the sample set while it's on.
// The database decides what the public sees (approved, not paused, for everyone,
// within its hours). Only the visible map area is ever sent to the server.
// Works in the browser and on the server.

import { libraryObject } from "@/lib/library/objects";
import type { MapBounds } from "@/lib/map/engine";
import { anonClient } from "@/lib/supabase/anon";
import { browserClient } from "@/lib/supabase/browser";
import { dropFromJson, type DropJson } from "./json";
import { sampleDrops, showSamples } from "./sample";
import type { PublicDrop } from "./types";

const WORLD: MapBounds = { west: -180, south: -85, east: 180, north: 85 };

function db() {
  return typeof window === "undefined" ? anonClient() : browserClient();
}

/** Samples on the public map: live and visible to everyone. */
function samplesOnMap(): PublicDrop[] {
  return showSamples ? sampleDrops.filter((d) => d.status === "live" && d.audience === "everyone") : [];
}

function inBounds(drop: PublicDrop, b: MapBounds) {
  const { lat, lng } = drop.placement;
  return lat >= b.south && lat <= b.north && lng >= b.west && lng <= b.east;
}

async function rpcDrops(name: string, args: Record<string, unknown>): Promise<PublicDrop[]> {
  const client = db();
  if (!client) return [];
  const { data, error } = await client.rpc(name, args);
  if (error) {
    // The map keeps working with whatever else it has.
    console.warn(`Couldn't load drops (${name}):`, error.message);
    return [];
  }
  return ((data ?? []) as DropJson[]).map(dropFromJson);
}

/** Public drops inside the visible map area. */
export async function listDropsInBounds(bounds: MapBounds): Promise<PublicDrop[]> {
  const found = await rpcDrops("public_drops_in_bounds", { ...bounds, max_results: 300 });
  return [...samplesOnMap().filter((d) => inBounds(d, bounds)), ...found];
}

/** Public drops anywhere, for when the map can't load and the list has to stand alone. */
export async function listPublicDrops(): Promise<PublicDrop[]> {
  return listDropsInBounds(WORLD);
}

/** Public drops whose words (title, who posted it, description, object) contain every search word. */
export async function searchDrops(query: string, limit = 3): Promise<PublicDrop[]> {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) return [];
  const samples = samplesOnMap().filter((d) => {
    const object = d.look.kind === "library" ? (libraryObject(d.look.objectId)?.name ?? "") : "";
    const text = `${d.title} ${d.owner.name} ${d.description} ${object}`.toLowerCase();
    return words.every((w) => text.includes(w));
  });
  const found = await rpcDrops("search_public_drops", { query, max_results: limit });
  return [...samples, ...found].slice(0, limit);
}
