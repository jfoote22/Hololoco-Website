// Place search through the Mapbox Geocoding API (v6). It's called from the browser
// with the public token. It sends the typed words and the centre of the map being
// viewed, never the person's own location.

import type { LngLat, MapBounds } from "./engine";

export type Place = {
  id: string;
  name: string;
  /** The rest of the address, e.g. "New York, New York 10038, United States". */
  detail: string;
  center: LngLat;
  bounds?: MapBounds;
  /** address, street, neighborhood, locality, place, district, postcode, region, country */
  kind: string;
};

type Feature = {
  id: string;
  geometry: { coordinates: [number, number] };
  properties: {
    mapbox_id?: string;
    name: string;
    place_formatted?: string;
    feature_type: string;
    bbox?: [number, number, number, number];
  };
};

export async function searchPlaces(
  query: string,
  near: LngLat,
  accessToken: string,
  signal?: AbortSignal,
): Promise<Place[]> {
  const url = new URL("https://api.mapbox.com/search/geocode/v6/forward");
  url.searchParams.set("q", query);
  url.searchParams.set("proximity", `${near.lng.toFixed(4)},${near.lat.toFixed(4)}`);
  url.searchParams.set("autocomplete", "true");
  url.searchParams.set("limit", "5");
  url.searchParams.set("access_token", accessToken);

  const res = await fetch(url, { signal });
  if (!res.ok) throw new Error(`Place search failed (${res.status})`);
  const json = (await res.json()) as { features?: Feature[] };

  return (json.features ?? []).map((f) => {
    const bbox = f.properties.bbox;
    return {
      id: f.properties.mapbox_id ?? f.id,
      name: f.properties.name,
      detail: f.properties.place_formatted ?? "",
      center: { lng: f.geometry.coordinates[0], lat: f.geometry.coordinates[1] },
      bounds: bbox ? { west: bbox[0], south: bbox[1], east: bbox[2], north: bbox[3] } : undefined,
      kind: f.properties.feature_type,
    };
  });
}

/** How close to zoom in on each kind of place. */
export function zoomForPlace(kind: string): number {
  switch (kind) {
    case "address":
    case "secondary_address":
    case "street":
      return 17.2;
    case "neighborhood":
    case "postcode":
    case "block":
      return 15.5;
    case "locality":
    case "place":
      return 14;
    case "district":
      return 11;
    case "region":
      return 7;
    case "country":
      return 5;
    default:
      return 15;
  }
}
