// Where drops come from. Phase 1 reads the sample set; Phase 2 replaces these
// functions with Supabase queries that return the same shapes. From then on the
// database decides what the public sees (live, everyone-audience drops within
// their hours), and only the visible map area is ever sent to the server.

import { libraryObject } from "@/lib/library/objects";
import type { MapBounds } from "@/lib/map/engine";
import { sampleDrops } from "./sample";
import type { PublicDrop } from "./types";

/** On the public map: live and visible to everyone. Link-only drops open from their link. */
function isOnMap(drop: PublicDrop) {
  return drop.status === "live" && drop.audience === "everyone";
}

function inBounds(drop: PublicDrop, b: MapBounds) {
  const { lat, lng } = drop.placement;
  return lat >= b.south && lat <= b.north && lng >= b.west && lng <= b.east;
}

/** One drop by id, for its own page. Link-only drops are included: having the link is the point. */
export async function getDrop(id: string): Promise<PublicDrop | null> {
  return sampleDrops.find((d) => d.id === id && d.status === "live") ?? null;
}

/** Public drops inside the visible map area. */
export async function listDropsInBounds(bounds: MapBounds): Promise<PublicDrop[]> {
  return sampleDrops.filter((d) => isOnMap(d) && inBounds(d, bounds));
}

/** Every public drop, for when the map can't load and the list has to stand alone. */
export async function listPublicDrops(): Promise<PublicDrop[]> {
  return sampleDrops.filter(isOnMap);
}

/** Public drops whose words (title, who posted it, description, object) match every search word. */
export async function searchDrops(query: string, limit = 3): Promise<PublicDrop[]> {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) return [];
  return sampleDrops
    .filter((d) => {
      if (!isOnMap(d)) return false;
      const object = d.look.kind === "library" ? (libraryObject(d.look.objectId)?.name ?? "") : "";
      const text = `${d.title} ${d.owner.name} ${d.description} ${object}`.toLowerCase();
      return words.every((w) => text.includes(w));
    })
    .slice(0, limit);
}

/** Ids to prerender drop pages for. */
export function knownDropIds(): string[] {
  return sampleDrops.map((d) => d.id);
}
