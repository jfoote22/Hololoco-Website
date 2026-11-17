// Putting a found event on the map: a venue already placed, else its street address
// (Mapbox, stored permanently, which Mapbox allows only with permanent=true), else
// Claude's own estimate, which the reviewer is told to check.

import type postgres from "https://deno.land/x/postgresjs@v3.4.5/mod.js";
import type { FoundEvent } from "./topics.ts";

export type Area = { id: string; name: string; lat: number; lng: number; radius_km: number; time_zone: string };

export type Placed = { lat: number; lng: number; placed_by: "venue" | "address" | "estimate"; venue_key: string | null };

/** "austin|moody center": the same venue however it's written. */
export function venueKey(areaId: string, event: FoundEvent): string | null {
  const name = (event.venue || event.address).toLowerCase()
    .replace(/&/g, " and ")
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/^(the) /, "")
    .trim();
  return name ? `${areaId}|${name}` : null;
}

function metresBetween(aLat: number, aLng: number, bLat: number, bLng: number) {
  const r = (d: number) => (d * Math.PI) / 180;
  const x = r(bLng - aLng) * Math.cos(r((aLat + bLat) / 2));
  const y = r(bLat - aLat);
  return Math.sqrt(x * x + y * y) * 6371008.8;
}

const inArea = (area: Area, lat: number, lng: number) =>
  Number.isFinite(lat) && Number.isFinite(lng) && metresBetween(area.lat, area.lng, lat, lng) <= area.radius_km * 1000;

/** The street address's spot, when Mapbox is sure of it. */
async function geocode(area: Area, address: string): Promise<{ lat: number; lng: number } | null> {
  const token = Deno.env.get("MAPBOX_TOKEN");
  // Only real street addresses: a venue name alone lands on the middle of town.
  if (!token || !/\d/.test(address)) return null;
  const dLat = area.radius_km / 111;
  const dLng = area.radius_km / (111 * Math.cos((area.lat * Math.PI) / 180));
  const url = new URL("https://api.mapbox.com/search/geocode/v6/forward");
  url.searchParams.set("q", address);
  url.searchParams.set("proximity", `${area.lng},${area.lat}`);
  url.searchParams.set("bbox", [area.lng - dLng, area.lat - dLat, area.lng + dLng, area.lat + dLat].map((n) => n.toFixed(4)).join(","));
  url.searchParams.set("country", "us");
  url.searchParams.set("types", "address");
  url.searchParams.set("limit", "1");
  url.searchParams.set("permanent", "true");
  url.searchParams.set("access_token", token);
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(6000) });
    if (!response.ok) return null;
    const feature = (await response.json())?.features?.[0];
    const confidence = feature?.properties?.match_code?.confidence;
    if (!feature || !["exact", "high", "medium"].includes(confidence)) return null;
    const [lng, lat] = feature.geometry.coordinates as [number, number];
    return inArea(area, lat, lng) ? { lat, lng } : null;
  } catch {
    return null;
  }
}

export async function placeEvent(sql: postgres.Sql, area: Area, event: FoundEvent): Promise<Placed | null> {
  const key = venueKey(area.id, event);

  if (key) {
    const [venue] = await sql`select lat, lng, source from public.found_venues where key = ${key}`;
    // An estimate gets another chance at the street address; anything better is kept.
    if (venue && venue.source !== "estimate") {
      return { lat: venue.lat, lng: venue.lng, placed_by: "venue", venue_key: key };
    }
  }

  const spot = await geocode(area, event.address);
  if (spot) {
    if (key) {
      await sql`
        insert into public.found_venues (key, name, address, lat, lng, source)
        values (${key}, ${event.venue || event.address}, ${event.address}, ${spot.lat}, ${spot.lng}, 'address')
        on conflict (key) do update
          set lat = excluded.lat, lng = excluded.lng, address = excluded.address, source = 'address', updated_at = now()
          where public.found_venues.source = 'estimate'`;
    }
    return { ...spot, placed_by: "address", venue_key: key };
  }

  if (key) {
    const [venue] = await sql`select lat, lng from public.found_venues where key = ${key}`;
    if (venue) return { lat: venue.lat, lng: venue.lng, placed_by: "estimate", venue_key: key };
  }

  if (event.lat !== null && event.lng !== null && inArea(area, event.lat, event.lng)) {
    if (key) {
      await sql`
        insert into public.found_venues (key, name, address, lat, lng, source)
        values (${key}, ${event.venue || event.address}, ${event.address}, ${event.lat}, ${event.lng}, 'estimate')
        on conflict (key) do nothing`;
    }
    return { lat: event.lat, lng: event.lng, placed_by: "estimate", venue_key: key };
  }
  return null;
}
