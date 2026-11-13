// The app talks to the map only through this interface, so the vendor can change
// (Mapbox at launch; another 3D map later if cost or quality calls for it).
// The Mapbox adapter that implements it lands in Phase 1.

import type { DropType, Placement } from "@/lib/drops/types";

export type LngLat = { lng: number; lat: number };

export type MapBounds = { west: number; south: number; east: number; north: number };

export type MapPin = {
  id: string;
  type: DropType;
  title: string;
  placement: Placement;
  /** GLB to show when zoomed in close; pins alone are shown further out. */
  modelUrl?: string;
};

export interface MapEngine {
  /** Attach the map to a container element and resolve once it can draw. */
  mount(container: HTMLElement, view: { center: LngLat; zoom: number }): Promise<void>;
  destroy(): void;

  /** Replace every pin on the map. */
  setPins(pins: MapPin[]): void;
  flyTo(center: LngLat, zoom?: number): void;

  /** The visible area. It is the only location the server ever receives. */
  getBounds(): MapBounds;
  onMove(handler: (bounds: MapBounds) => void): () => void;
  onPinSelect(handler: (id: string) => void): () => void;

  /** Placement mode for the add flow: the next tap on the map picks a spot. */
  pickLocation(): Promise<LngLat | null>;
}
