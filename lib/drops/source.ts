// Other people's drops around the map, from the database plus the sample set
// while it's on. The database decides what's public (approved, not paused, for
// everyone, within its hours). Only the visible map area is sent to the server.

import type { MapBounds } from "@/lib/map/engine";
import { browserClient } from "@/lib/supabase/browser";
import { dropFromJson, type DropJson } from "./json";
import { sampleDrops, showSamples } from "./sample";
import type { PublicDrop } from "./types";

/** Samples on the public map: live and visible to everyone. */
function samplesOnMap(): PublicDrop[] {
  return showSamples ? sampleDrops.filter((d) => d.status === "live" && d.audience === "everyone") : [];
}

function inBounds(drop: PublicDrop, b: MapBounds) {
  const { lat, lng } = drop.placement;
  return lat >= b.south && lat <= b.north && lng >= b.west && lng <= b.east;
}

async function rpcDrops(name: string, args: Record<string, unknown>): Promise<PublicDrop[]> {
  const client = browserClient();
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
